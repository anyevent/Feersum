#include "EVAPI.h"
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <errno.h>

#include "ppport.h"

#include "picohttpparser/picohttpparser.c"

#include "rinq.c"

#define MAX_HEADERS 128

#ifdef DEBUG
#define trace(f_, ...) warn(f_, ##__VA_ARGS__)
#else
#define trace(...)
#endif

struct http_client_req {
    const char* method;
    size_t method_len;
    const char* path; 
    size_t path_len;
    int minor_version;
    size_t num_headers;
    struct phr_header headers[MAX_HEADERS];
};

// enough to hold a 64-bit signed integer (which is 20+1 chars) plus nul
#define CLIENT_LABEL_LENGTH 24

struct http_client {
    char label[CLIENT_LABEL_LENGTH];
    SV *self;
    SV *drain_cb;

    int fd;
    struct ev_io read_ev_io;
    struct ev_io write_ev_io;
    struct ev_loop *loop;

    char *r_buf;
    size_t r_offset;
    size_t r_len;

    char *w_buf;
    size_t w_offset;
    size_t w_len;

    size_t body_offset;

    struct http_client_req *req;

    int in_callback;
};

static void try_client_write(EV_P_ struct ev_io *w, int revents);
static void client_write_ready (struct http_client *c);
static void try_client_read(EV_P_ struct ev_io *w, int revents);
static void call_http_request_callback(EV_P_ struct http_client *c);

static HV *stash, *http_client_stash;

static SV *request_cb_cv = NULL;

static ev_io accept_w;
static ev_prepare ep;
static ev_check   ec;
struct ev_idle    ei;

static struct rinq *request_ready_rinq = NULL;

static int
setnonblock(int fd)
{
    int flags;

    flags = fcntl(fd, F_GETFL);
    if (flags < 0)
            return flags;
    flags |= O_NONBLOCK;
    if (fcntl(fd, F_SETFL, flags) < 0)
            return -1;

    return 0;
}

static struct http_client *
new_http_client (EV_P_ int client_fd)
{
    // allocate an SV that can hold the http_client PLUS a string for the fd
    // so that dumping the SV from interpreter-land 
    SV *self = newSV(0);
    SvUPGRADE(self, SVt_PVMG); // ensures sv_bless doesn't reallocate
    SvGROW(self, sizeof(struct http_client));
    SvPOK_only(self);
    SvIOK_on(self);
    SvIVX(self) = client_fd;

    struct http_client *c = (struct http_client *)SvPVX(self);
    Zero(c, 1, struct http_client);

    STRLEN label_len = snprintf(
        c->label, CLIENT_LABEL_LENGTH, "%"IVdf, client_fd);

    // make the var readonly and make the visible portion just the fd number
    SvCUR_set(self, label_len);
    SvREADONLY_on(self); // turn off later for blessing

    c->self = self;
    c->fd = client_fd;
    setnonblock(c->fd);

    c->loop = loop; // from EV_P_

    // TODO: these initializations should be Lazy
    ev_io_init(&c->read_ev_io, try_client_read, client_fd, EV_READ);
    c->read_ev_io.data = (void *)c;

    ev_io_init(&c->write_ev_io, try_client_write, client_fd, EV_WRITE);
    c->write_ev_io.data = (void *)c;

#ifdef DEBUG
    sv_dump(self);
#endif
    trace("made client self=%p, c=%p, cur=%d, len=%d, structlen=%d, refcnt=%d\n",
        self, c, SvCUR(self), SvLEN(self), sizeof(struct http_client), SvREFCNT(self));

    return c;
}

// for use in the typemap:
static struct http_client *
sv_2http_client (SV *rv)
{
    if (!sv_isa(rv,"Socialtext::EvHttp::Client"))
       croak("object is not of type Socialtext::EvHttp::Client");
    return (struct http_client *)SvPVX(SvRV(rv));
}

static SV*
http_client_2sv (struct http_client *c)
{
    SV *rv = newRV_inc(c->self);
    if (!SvOBJECT(c->self)) {
        trace("c->self not yet an object, SvCUR:%d\n",SvCUR(c->self));
        SvREADONLY_off(c->self);
        // XXX: should this block use newRV_noinc instead?
        sv_bless(rv, http_client_stash);
        SvREADONLY_on(c->self);
    }
    return rv;
}

static void
process_request_ready_rinq (EV_P)
{
    while (request_ready_rinq) {
        struct http_client *c =
            (struct http_client *)rinq_shift(&request_ready_rinq);
        trace("rinq shifted c=%p, head=%p\n", c, request_ready_rinq);

        call_http_request_callback(EV_A, c);

        if (c->w_buf && (c->w_len - c->w_offset) > 0) {
            client_write_ready(c);
        }
    }
}

static void
prepare_cb (EV_P_ ev_prepare *w, int revents)
{
    trace("prepare!\n");
    if (!ev_is_active(&accept_w)) {
        ev_io_start(EV_A, &accept_w);
        //ev_prepare_stop(EV_A, w);
    }
}

static void
check_cb (EV_P_ ev_check *w, int revents)
{
    trace("check! head=%p\n", request_ready_rinq);
    process_request_ready_rinq(EV_A);
}

static void
idle_cb (EV_P_ ev_idle *w, int revents)
{
    trace("idle! head=%p\n", request_ready_rinq);
    process_request_ready_rinq(EV_A);
    ev_idle_stop(EV_A, w);
}

#define dCLIENT struct http_client *c = (struct http_client *)w->data

static void
try_client_write(EV_P_ struct ev_io *w, int revents)
{
    dCLIENT;
    ssize_t wrote;

    trace("going to write %d %ld %p\n",w->fd, c->w_len, c->w_buf);
    wrote = write(w->fd, c->w_buf + c->w_offset, c->w_len - c->w_offset);
    if (wrote == -1) {
        if (errno == EAGAIN) goto try_write_again;
        perror("try_client_write");
        goto try_write_error;
    }

    c->w_offset += wrote;
    if (c->w_len - c->w_offset == 0) {
        trace("All done with %d\n",w->fd);
        ev_io_stop(EV_A, w);
        free(c->w_buf);
        c->w_buf = NULL;
        c->w_offset = c->w_len = 0;
        // TODO: call the drain callback
        SvREFCNT_dec(c->self);
    }
    return;

try_write_error:
    ev_io_stop(EV_A, w);
    close(w->fd);
    SvREFCNT_dec(c->self);
    return;

try_write_again:
    trace("write again %d\n",w->fd);
    if (!ev_is_active(w)) {
        ev_io_start(EV_A, w);
    }
    return;
}

static int
try_parse_http(struct http_client *c, size_t last_len)
{
    struct http_client_req *req = c->req;
    if (!req) {
        req = (struct http_client_req *)
            calloc(1,sizeof(struct http_client_req));
        req->num_headers = MAX_HEADERS;
        c->req = req;
    }
    return phr_parse_request(c->r_buf, c->r_len,
        &req->method, &req->method_len,
        &req->path, &req->path_len, &req->minor_version,
        req->headers, &req->num_headers, 
        last_len);
}

#define READ_CHUNK 4096

static void
try_client_read(EV_P_ ev_io *w, int revents)
{
    dCLIENT;
    int attempts = 0;

    trace("try read %d\n",w->fd);

    if (c->r_len == 0) {
        trace("init rbuf for %d\n",w->fd);
        c->r_len = 2 * READ_CHUNK;
        c->r_buf = (char *)malloc(c->r_len);
        c->r_offset = 0;
    }

    while (attempts < 20) {
        if (c->r_len - c->r_offset < READ_CHUNK) {
            trace("moar memory %d\n",w->fd);
            // XXX: unbounded, unchecked realloc
            c->r_len += READ_CHUNK;
            c->r_buf = (char *)realloc(c->r_buf, c->r_len);
        }

        attempts ++;
        ssize_t got_n = read(w->fd, c->r_buf + c->r_offset, READ_CHUNK);

        if (got_n == -1) {
            int errno_copy = errno;
            if (errno_copy == EAGAIN) goto try_read_again;
            perror("try_client_read");
            goto try_read_error;
        }
        else if (got_n == 0) {
            trace("EOF %d after %d\n",w->fd,c->r_offset);
            goto try_read_error;
        }
        else {
            trace("read %d %d\n", w->fd, got_n);
            c->r_offset += got_n;
            int ret = try_parse_http(c, (size_t)got_n);
            if (ret == -1) goto try_read_error;
            if (ret == -2) goto try_read_again;
            c->body_offset = (size_t)ret;
            trace("GOT HTTP %d: %.*s", c->r_len, c->body_offset, c->r_buf);
            ev_io_stop(EV_A, w);

            
            // XXX: here's where we'd check the content length or chunked
            // input stuff, read the body if it's not too big
            
            trace("rinq push: c=%p, head=%p\n", c, request_ready_rinq);
            rinq_push(&request_ready_rinq, c);
            if (!ev_is_active(&ei)) {
                ev_idle_start(EV_A, &ei);
            }
            break;
        }
    }

    return;

try_read_again:
    trace("read again %d\n", w->fd);
    if (!ev_is_active(w)) {
        ev_io_start(EV_A,w);
    }
    return;

try_read_error:
    ev_io_stop(EV_A, w);
    close(w->fd);
    SvREFCNT_dec(c->self);
    return;
}

static void
accept_cb (EV_P_ ev_io *w, int revents)
{
    int client_fd;
    struct sockaddr_in client_sockaddr;
    socklen_t client_socklen = sizeof(struct sockaddr_in);

    trace("accept! %08x %d\n", revents, revents & EV_READ);
    // TODO: accept as many as possible
    client_fd = accept(w->fd,
                       (struct sockaddr *)&client_sockaddr, &client_socklen);

    struct http_client *c = new_http_client(EV_A, client_fd);
    // XXX: good idea to read right away?
    // try_client_read(EV_A, &c->read_ev_io, EV_READ);
    ev_io_start(EV_A, &c->read_ev_io);
}

static void
client_write_ready (struct http_client *c)
{
    if (c->in_callback) return;

    if (ev_is_active(&c->write_ev_io)) {
        // just wait for event to fire
    }
    else {
        // attempt a non-blocking write immediately
        try_client_write(c->loop, &c->write_ev_io, EV_WRITE);
    }
}

void
call_http_request_callback (EV_P_ struct http_client *c)
{
    dSP;
    SV *sv_self;

    c->in_callback++;

    sv_self = http_client_2sv(c);

    trace("request callback c=%p self=%p\n", c, sv_self);

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    XPUSHs(sv_2mortal(sv_self));
    PUTBACK;

    trace("calling request callback...\n");

    call_sv(request_cb_cv, G_DISCARD|G_EVAL|G_VOID);

    trace("called request callback...\n");

    if (SvTRUE(ERRSV)) {
        STRLEN len;
        char *err = SvPV(ERRSV,len);
        trace("an error was thrown: %.*s\n",len,err);
        SPAGAIN;
        PUSHMARK(SP);
        PUTBACK;
        call_sv(get_sv("Socialtext::EvHttp::DIED",1),
                G_DISCARD|G_EVAL|G_VOID|G_KEEPERR);
    }

    trace("leaving request callback\n");
    FREETMPS;
    LEAVE;

    c->in_callback--;
}

MODULE = Socialtext::EvHttp		PACKAGE = Socialtext::EvHttp		

PROTOTYPES: ENABLE

void
accept_on_fd(SV *self, int fd)
    PPCODE:
    {
        trace("going to accept on %d\n",fd);

        ev_prepare_init(&ep, prepare_cb);
        ev_prepare_start(EV_DEFAULT, &ep);

        ev_check_init(&ec, check_cb);
        ev_check_start(EV_DEFAULT, &ec);

        ev_idle_init(&ei, idle_cb);

        ev_io_init(&accept_w, accept_cb, fd, EV_READ);
    }

void
request_handler(SV *self, SV *cb)
    PPCODE:
{
    if (!SvROK(cb) || SvTYPE(SvRV(cb)) != SVt_PVCV) {
        croak("must supply a code reference");
    }
    if (request_cb_cv)
        SvREFCNT_dec(request_cb_cv);
    request_cb_cv = SvRV(cb);
    SvREFCNT_inc(request_cb_cv);
    trace("assigned request handler %p\n", SvRV(cb));
}

void
DESTROY (SV *self)
    PPCODE:
{
    if (request_cb_cv)
        SvREFCNT_dec(request_cb_cv);
}

MODULE = Socialtext::EvHttp	PACKAGE = Socialtext::EvHttp::Client

void
on_drain (struct http_client *c, SV *cb)
    PPCODE:
{
    if (!(SvOK(cb) && SvROK(cb) && SvTYPE(SvRV(cb)) == SVt_PVCV)) {
        croak("expected code reference");
    }
    if (c->drain_cb) {
        SvREFCNT_dec(c->drain_cb);
    }
    c->drain_cb = newRV_inc(SvRV(cb));
}

void
send_response (struct http_client *c, SV *message, AV *headers, SV *body)
    PPCODE:
{
    char *ptr;
    STRLEN len;
    I32 i, avl;
    SV *tmp = NEWSV(0,0);
    trace("send response c=%p\n",c);

    avl = av_len(headers);
    if (avl < 0 || (avl % 2 != 1)) {
        croak("even-length array of headers expected\n");
    }

    sv_catpv(tmp, "HTTP/1.0 ");
    sv_catsv(tmp, message);
    sv_catpv(tmp, "\r\n");

    for (i=0; i<=av_len(headers); i++) {
        SV **elt = av_fetch(headers, i, 0);
        sv_catsv(tmp, *elt);
        sv_catpvn(tmp, (i%2) ? "\r\n" : ": ", 2);
    }

    ptr = SvPV(body, len);
    sv_catpvf(tmp, "Content-Length: %d\r\n\r\n", len);
    sv_catpvn(tmp, ptr, len);

    ptr = SvPV(tmp, len);
    c->w_buf = (char *)malloc(len);
    c->w_len = len;
    memcpy(c->w_buf, ptr, len);
    SvREFCNT_dec(tmp);

    free(c->r_buf); c->r_buf = NULL;
    free(c->req); c->req = NULL;

    client_write_ready(c);
}

void
DESTROY (struct http_client *c)
    PPCODE:
{
    trace("DESTROY client %p\n", c);
    if (c->drain_cb) SvREFCNT_dec(c->drain_cb);
    if (c->r_buf) free(c->r_buf);
    if (c->w_buf) free(c->w_buf);
    if (c->req) free(c->req);
    if (c->fd) close(c->fd);
#ifdef DEBUG
    sv_dump(c->self);
    // overwrite for debugging
    Poison(c, 1, struct http_client);
#endif
}

MODULE = Socialtext::EvHttp	PACKAGE = Socialtext::EvHttp		

BOOT:
    {
        stash = gv_stashpv("Socialtext::EvHttp", 1);
        http_client_stash = gv_stashpv("Socialtext::EvHttp::Client", 1);
        I_EV_API("Socialtext::EvHttp");
    }
