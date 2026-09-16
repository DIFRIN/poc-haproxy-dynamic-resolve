// Command iot-mock is the POC's IoT backend: the final destination of proxied
// HTTP CONNECT tunnels and the only component in the POC that terminates
// application-layer TLS end to end. It exists to be measured, so it does four
// things and nothing more:
//
//  1. terminates mTLS on LISTEN_TLS (default :443), requiring and verifying a
//     client certificate against the CA in CLIENT_CA;
//  2. serves the real device-facing workload -- PUT <any path>, body consumed,
//     small JSON result returned -- plus a handful of trivial endpoints and a
//     synthetic payload generator;
//  3. publishes monotonic counters on a plain HTTP metrics listener;
//  4. never logs per request -- at 6000 rps that would dominate the benchmark
//     and flood the logs.
//
// The method matters. The real IoT devices accept PUT, so PUT is what the
// workload generator measures. GET /health is an INFRASTRUCTURE health probe
// (container healthchecks, readiness gates) and is never the measured
// workload.
//
// Standard library only, deliberately: the image must build with no module
// downloads (no network, no proxy, no checksum database).
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	// defaultListenTLS is the production-typical HTTPS port, so the CONNECT
	// authority in the POC is "iot-mock.test.domain:443".
	defaultListenTLS = ":443"
	// defaultListenMetrics is a plain HTTP listener, handy for curl.
	defaultListenMetrics = ":9090"

	// defaultPayloadBytes is the size of GET /payload with no ?bytes=.
	defaultPayloadBytes = 1024
	// maxPayloadBytes caps GET /payload so a typo cannot make the process
	// allocate or stream gigabytes.
	maxPayloadBytes = 64 << 20 // 64 MiB

	// handshakeTimeout bounds a single TLS handshake (including client
	// certificate verification) so half-open connections cannot pin a
	// goroutine forever.
	handshakeTimeout = 10 * time.Second
	// shutdownTimeout is how long http.Server.Shutdown is given to drain.
	shutdownTimeout = 5 * time.Second

	// handshakeLogLimit / handshakeLogEvery rate-limit handshake-failure
	// logging: a benchmark that drives deliberate mTLS failures would
	// otherwise produce one log line per rejected connection, which is
	// exactly the log flood this server is supposed to avoid.
	handshakeLogLimit = 20
	handshakeLogEvery = 1000

	// acceptBackoff bounds the sleep after a transient accept() error.
	acceptBackoff = 50 * time.Millisecond
)

// fillerChunk is 64 KiB of repeatable filler. Repeatability matters: two runs
// of the same test must transfer byte-identical payloads. The period is prime
// so the pattern is not trivially compressible at buffer boundaries.
var fillerChunk = func() []byte {
	const period = 251
	b := make([]byte, 64*1024)
	for i := range b {
		b[i] = byte(i % period)
	}
	return b
}()

// counters holds every metric this server publishes.
//
// All of them are monotonic except connections_active, which is a gauge and
// therefore a signed integer: it must go down as well as up.
type counters struct {
	connectionsTotal     atomic.Uint64
	connectionsActive    atomic.Int64
	tlsHandshakesTotal   atomic.Uint64
	tlsHandshakeFailures atomic.Uint64
	mtlsRejections       atomic.Uint64
	httpRequestsTotal    atomic.Uint64
	httpErrorsTotal      atomic.Uint64
	bytesSentTotal       atomic.Uint64

	// Handler time is the one thing that cannot be a plain atomic.Uint64: it
	// is a float sum plus a count. A mutex is simpler than bit-twiddling the
	// duration through math.Float64bits, and the critical section is a few
	// nanoseconds against a syscall-bound request path.
	durMu    sync.Mutex
	durSum   float64
	durCount uint64
}

func (c *counters) observeDuration(d time.Duration) {
	c.durMu.Lock()
	c.durSum += d.Seconds()
	c.durCount++
	c.durMu.Unlock()
}

func (c *counters) durations() (sum float64, count uint64) {
	c.durMu.Lock()
	defer c.durMu.Unlock()
	return c.durSum, c.durCount
}

// snapshot is the JSON shape of GET /stats.
type snapshot struct {
	ConnectionsTotal            uint64  `json:"connections_total"`
	ConnectionsActive           int64   `json:"connections_active"`
	TLSHandshakesTotal          uint64  `json:"tls_handshakes_total"`
	TLSHandshakeFailuresTotal   uint64  `json:"tls_handshake_failures_total"`
	MTLSRejectionsTotal         uint64  `json:"mtls_rejections_total"`
	HTTPRequestsTotal           uint64  `json:"http_requests_total"`
	HTTPErrorsTotal             uint64  `json:"http_errors_total"`
	RequestDurationSecondsSum   float64 `json:"request_duration_seconds_sum"`
	RequestDurationSecondsCount uint64  `json:"request_duration_seconds_count"`
	BytesSentTotal              uint64  `json:"bytes_sent_total"`
}

func (c *counters) snapshot() snapshot {
	sum, count := c.durations()
	return snapshot{
		ConnectionsTotal:            c.connectionsTotal.Load(),
		ConnectionsActive:           c.connectionsActive.Load(),
		TLSHandshakesTotal:          c.tlsHandshakesTotal.Load(),
		TLSHandshakeFailuresTotal:   c.tlsHandshakeFailures.Load(),
		MTLSRejectionsTotal:         c.mtlsRejections.Load(),
		HTTPRequestsTotal:           c.httpRequestsTotal.Load(),
		HTTPErrorsTotal:             c.httpErrorsTotal.Load(),
		RequestDurationSecondsSum:   sum,
		RequestDurationSecondsCount: count,
		BytesSentTotal:              c.bytesSentTotal.Load(),
	}
}

// prometheus renders the same numbers in Prometheus text exposition format, so
// a scrape job and a human with curl can both consume this listener.
func (c *counters) prometheus() string {
	s := c.snapshot()
	var b strings.Builder

	counter := func(name, help string, v uint64) {
		fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s counter\n%s %d\n", name, help, name, name, v)
	}
	gauge := func(name, help string, v int64) {
		fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s gauge\n%s %d\n", name, help, name, name, v)
	}

	counter("connections_total",
		"TCP connections accepted on the mTLS listener.", s.ConnectionsTotal)
	gauge("connections_active",
		"TCP connections currently open on the mTLS listener.", s.ConnectionsActive)
	counter("tls_handshakes_total",
		"TLS handshakes completed successfully.", s.TLSHandshakesTotal)
	counter("tls_handshake_failures_total",
		"TLS handshakes that failed for any reason.", s.TLSHandshakeFailuresTotal)
	counter("mtls_rejections_total",
		"Handshakes rejected because the client certificate was missing, untrusted or expired. Also counted in tls_handshake_failures_total.", s.MTLSRejectionsTotal)
	counter("http_requests_total",
		"HTTP requests handled on the mTLS listener.", s.HTTPRequestsTotal)
	counter("http_errors_total",
		"HTTP responses with status >= 400 on the mTLS listener.", s.HTTPErrorsTotal)

	fmt.Fprintf(&b, "# HELP request_duration_seconds Server-side handler time on the mTLS listener.\n")
	fmt.Fprintf(&b, "# TYPE request_duration_seconds summary\n")
	fmt.Fprintf(&b, "request_duration_seconds_sum %s\n", strconv.FormatFloat(s.RequestDurationSecondsSum, 'g', -1, 64))
	fmt.Fprintf(&b, "request_duration_seconds_count %d\n", s.RequestDurationSecondsCount)

	counter("bytes_sent_total",
		"Response body bytes written on the mTLS listener.", s.BytesSentTotal)

	return b.String()
}

// app carries the counters and serves the mTLS endpoints.
type app struct {
	c *counters
}

// instrument is the only place request-level metrics are touched. It records
// the status and byte count the handler actually produced, not what it
// intended to produce.
func (a *app) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		a.c.httpRequestsTotal.Add(1)

		cw := &countingWriter{ResponseWriter: w}
		next.ServeHTTP(cw, r)

		if cw.status == 0 {
			// Handler wrote nothing at all: net/http will send 200 on return.
			cw.status = http.StatusOK
		}
		if cw.status >= 400 {
			a.c.httpErrorsTotal.Add(1)
		}
		a.c.bytesSentTotal.Add(cw.bytes)
		a.c.observeDuration(time.Since(start))
	})
}

// routes builds the mTLS listener's mux. Anything that is not one of the four
// documented method+path pairs is a 404.
//
// PUT is handled AHEAD of the mux, because it is the device-facing workload and
// applies to every path: the device does not interpret the path or the naming,
// it is addressed by the SNI the proxy already routed on. Handling it here also
// means PUT /health is the workload and not the probe -- the probe is GET only.
func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			notFound(w)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Length", "2")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok")
	})
	mux.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			notFound(w)
			return
		}
		// Echo the body verbatim. Content-Length is deliberately not set:
		// the request may be chunked, in which case the response is too.
		w.Header().Set("Content-Type", r.Header.Get("Content-Type"))
		w.WriteHeader(http.StatusOK)
		_, _ = io.Copy(w, r.Body)
	})
	mux.HandleFunc("/payload", a.handlePayload)
	mux.HandleFunc("/", a.handleRoot)
	return a.instrument(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			a.handlePut(w, r)
			return
		}
		mux.ServeHTTP(w, r)
	}))
}

// handlePut serves the device-facing workload: PUT to any path, body consumed
// in full, small JSON result returned.
//
// The body is read to EOF *before* the response is written, and this is not
// cosmetic. It is what lets a client reuse one tunnel for the next PUT: a
// response sent while an unread body is still in flight would desynchronise the
// connection (the unread bytes would be parsed as the next request line). The
// 10,000-tunnel scenario depends on exactly that reuse.
//
// Nothing is logged here. At thousands of rps a per-request log line costs more
// than the request it describes.
func (a *app) handlePut(w http.ResponseWriter, r *http.Request) {
	n, err := io.Copy(io.Discard, r.Body)
	if err != nil {
		// Truncated body or a client that vanished mid-write. The connection
		// cannot be framed correctly after this, so answer 400 and let the
		// client close it; the counter records it as an HTTP error.
		http.Error(w, "body read error", http.StatusBadRequest)
		return
	}

	sni, peer := "", ""
	if r.TLS != nil {
		sni = r.TLS.ServerName
		if len(r.TLS.PeerCertificates) > 0 {
			peer = r.TLS.PeerCertificates[0].Subject.CommonName
		}
	}
	body, err := json.Marshal(map[string]any{
		"sni":    sni,
		"peer":   peer,
		"path":   r.URL.Path,
		"bytes":  n,
		"method": http.MethodPut,
		"time":   time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		http.Error(w, "encoding error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// handleRoot serves GET / -- the identity endpoint, which reports what mTLS
// actually established rather than what the client claims.
func (a *app) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || r.URL.Path != "/" {
		notFound(w)
		return
	}

	sni, peer := "", ""
	if r.TLS != nil {
		sni = r.TLS.ServerName
		if len(r.TLS.PeerCertificates) > 0 {
			peer = r.TLS.PeerCertificates[0].Subject.CommonName
		}
	}
	body, err := json.Marshal(map[string]string{
		"sni":  sni,
		"peer": peer,
		"time": time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		http.Error(w, "encoding error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// handlePayload serves GET /payload?bytes=N with N bytes of repeatable filler.
func (a *app) handlePayload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		notFound(w)
		return
	}
	n := int64(defaultPayloadBytes)
	if raw := r.URL.Query().Get("bytes"); raw != "" {
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || v < 0 {
			http.Error(w, "bytes must be a non-negative integer", http.StatusBadRequest)
			return
		}
		n = v
	}
	if n > maxPayloadBytes {
		n = maxPayloadBytes
	}

	// An explicit Content-Length keeps the response off chunked encoding, so
	// the benchmark measures the payload and not the framing.
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(n, 10))
	w.WriteHeader(http.StatusOK)
	if err := writeRepeating(w, n); err != nil {
		// Client went away mid-payload. Not an error worth a log line.
		return
	}
}

func notFound(w http.ResponseWriter) {
	http.Error(w, "not found", http.StatusNotFound)
}

// writeRepeating writes n bytes of fillerChunk without allocating.
func writeRepeating(w io.Writer, n int64) error {
	for n > 0 {
		chunk := fillerChunk
		if int64(len(chunk)) > n {
			chunk = chunk[:n]
		}
		written, err := w.Write(chunk)
		n -= int64(written)
		if err != nil {
			return err
		}
	}
	return nil
}

// countingWriter records the status code and body byte count of a response.
type countingWriter struct {
	http.ResponseWriter
	status int
	bytes  uint64
}

func (w *countingWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *countingWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(p)
	w.bytes += uint64(n)
	return n, err
}

// Unwrap lets http.ResponseController reach Flush/Hijack/SetDeadline.
func (w *countingWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// chanListener adapts the accept loop's post-handshake connections to the
// http.Server's Listener interface.
//
// The handshake is completed by our own accept loop rather than by
// http.Server, because http.Server can only tell us about handshake failures
// by logging them -- it has no hook that distinguishes "no client
// certificate" from "untrusted client certificate". Doing the handshake
// ourselves is what makes mtls_rejections_total possible at all.
type chanListener struct {
	addr      net.Addr
	conns     chan net.Conn
	done      chan struct{}
	closeOnce sync.Once
}

func newChanListener(addr net.Addr) *chanListener {
	return &chanListener{
		addr:  addr,
		conns: make(chan net.Conn, 256),
		done:  make(chan struct{}),
	}
}

func (l *chanListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *chanListener) Close() error {
	l.closeOnce.Do(func() { close(l.done) })
	return nil
}

func (l *chanListener) Addr() net.Addr { return l.addr }

// deliver hands a completed handshake to the http.Server, or reports false if
// the listener is shutting down.
func (l *chanListener) deliver(c net.Conn) bool {
	select {
	case l.conns <- c:
		return true
	case <-l.done:
		return false
	}
}

// verifyClientCerts extracts the peer certificate used by GET / and confirms
// it chains to the configured CA, so a startup line tells the operator that
// mTLS is really enforced.
func loadClientCAPool(path string) (*x509.CertPool, *x509.Certificate, error) {
	pemBytes, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, fmt.Errorf("read CLIENT_CA %q: %w", path, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pemBytes) {
		return nil, nil, fmt.Errorf("CLIENT_CA %q contains no PEM certificates", path)
	}

	// Report the first certificate so the startup log shows which CA is
	// actually being enforced.
	var first *x509.Certificate
	if block, _ := pem.Decode(pemBytes); block != nil && block.Type == "CERTIFICATE" {
		if cert, err := x509.ParseCertificate(block.Bytes); err == nil {
			first = cert
		}
	}
	return pool, first, nil
}

// isClientCertError reports whether a handshake failure was caused by the
// client certificate rather than by, say, a protocol or cipher mismatch.
func isClientCertError(err error) bool {
	// Untrusted, expired or otherwise unverifiable certificate: Go 1.20+
	// wraps this in a *tls.CertificateVerificationError.
	var verifyErr *tls.CertificateVerificationError
	if errors.As(err, &verifyErr) {
		return true
	}
	// Missing certificate: crypto/tls returns a plain error here.
	msg := err.Error()
	return strings.Contains(msg, "client didn't provide a certificate") ||
		strings.Contains(msg, "failed to verify client certificate")
}

// handshakeLogger rate-limits handshake-failure logging.
type handshakeLogger struct {
	logger *log.Logger
	c      *counters
}

func (h *handshakeLogger) log(remote string, err error, certErr bool) {
	n := h.c.tlsHandshakeFailures.Load()
	if n <= handshakeLogLimit || n%handshakeLogEvery == 0 {
		kind := "handshake"
		if certErr {
			kind = "mtls"
		}
		h.logger.Printf("warn: %s failure #%d from %s: %v", kind, n, remote, err)
	}
}

// serveTLS runs the accept loop: accept, handshake, verify, hand off.
func serveTLS(
	ln net.Listener,
	tlsCfg *tls.Config,
	cl *chanListener,
	c *counters,
	logger *log.Logger,
) {
	hl := &handshakeLogger{logger: logger, c: c}
	// release decrements the active gauge exactly once, whichever path the
	// connection leaves by: handshake failure here, or StateClosed/StateHijacked
	// reported by http.Server.ConnState later.
	release := func() func() { return sync.OnceFunc(func() { c.connectionsActive.Add(-1) }) }

	for {
		raw, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				time.Sleep(acceptBackoff)
				continue
			}
			logger.Printf("error: accept on %s: %v", ln.Addr(), err)
			// Anything else (EMFILE and friends) has a real chance of being
			// transient under load; back off briefly instead of spinning.
			time.Sleep(acceptBackoff)
			continue
		}

		c.connectionsTotal.Add(1)
		c.connectionsActive.Add(1)
		free := release()

		go func(raw net.Conn) {
			tlsConn := tls.Server(raw, tlsCfg)
			// Bound the handshake; cleared below so it does not leak into
			// the request phase.
			_ = tlsConn.SetDeadline(time.Now().Add(handshakeTimeout))

			if err := tlsConn.Handshake(); err != nil {
				c.tlsHandshakeFailures.Add(1)
				certErr := isClientCertError(err)
				if certErr {
					c.mtlsRejections.Add(1)
				}
				hl.log(raw.RemoteAddr().String(), err, certErr)
				free()
				_ = tlsConn.Close()
				return
			}
			_ = tlsConn.SetDeadline(time.Time{})

			c.tlsHandshakesTotal.Add(1)
			// Hand the release function to http.Server.ConnState, which will
			// fire it when the connection closes or is hijacked.
			activeConns.Store(tlsConn, free)
			if !cl.deliver(tlsConn) {
				// Shutting down between handshake and hand-off.
				if free, ok := activeConns.LoadAndDelete(tlsConn); ok {
					free.(func())()
				}
				_ = tlsConn.Close()
			}
		}(raw)
	}
}

func main() {
	logger := log.New(os.Stdout, "iot-mock: ", log.LstdFlags|log.LUTC)

	if len(os.Args) > 1 && (os.Args[1] == "-h" || os.Args[1] == "--help") {
		fmt.Fprintf(os.Stdout, `iot-mock - mTLS IoT backend for the CONNECT proxy POC

Environment:
  LISTEN_TLS      mTLS HTTPS listener address (default %q)
  LISTEN_METRICS  plain HTTP metrics listener address (default %q)
  TLS_CERT        server certificate PEM (required)
  TLS_KEY         server private key PEM (required)
  CLIENT_CA       CA bundle used to verify client certificates (required)

Endpoints (mTLS listener):
  PUT /<any path>   the device-facing workload: body consumed, JSON result
  GET /health       infrastructure health probe only (never the workload)
  GET /             identity JSON (sni, peer, time)
  POST /echo        body echoed verbatim
  GET /payload?bytes=N
Endpoints (metrics listener): GET /stats, GET /metrics, GET /health
`, defaultListenTLS, defaultListenMetrics)
		return
	}

	certPath := os.Getenv("TLS_CERT")
	keyPath := os.Getenv("TLS_KEY")
	caPath := os.Getenv("CLIENT_CA")
	listenTLS := envOr("LISTEN_TLS", defaultListenTLS)
	listenMetrics := envOr("LISTEN_METRICS", defaultListenMetrics)

	// mTLS is not optional: without a server identity or a client CA there is
	// nothing meaningful to benchmark, so refuse to start rather than quietly
	// serving plaintext or accepting any client.
	var missing []string
	if certPath == "" {
		missing = append(missing, "TLS_CERT")
	}
	if keyPath == "" {
		missing = append(missing, "TLS_KEY")
	}
	if caPath == "" {
		missing = append(missing, "CLIENT_CA")
	}
	if len(missing) > 0 {
		logger.Fatalf("fatal: required environment variable(s) not set: %s (mTLS is mandatory in this POC)",
			strings.Join(missing, ", "))
	}

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		logger.Fatalf("fatal: load server keypair (TLS_CERT=%q TLS_KEY=%q): %v", certPath, keyPath, err)
	}
	if cert.Leaf == nil && len(cert.Certificate) > 0 {
		// Not all Go versions populate Leaf in LoadX509KeyPair; it is only
		// used for the startup log line.
		if leaf, err := x509.ParseCertificate(cert.Certificate[0]); err == nil {
			cert.Leaf = leaf
		}
	}
	clientCAs, caCert, err := loadClientCAPool(caPath)
	if err != nil {
		logger.Fatalf("fatal: %v", err)
	}

	tlsCfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientCAs:    clientCAs,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS12,
		// HTTP/1.1 only, on purpose: connection accounting stays honest and no
		// multiplexing can hide tunnels from the benchmark.
		NextProtos: []string{"http/1.1"},
	}

	c := &counters{}
	a := &app{c: c}

	// --- mTLS HTTPS listener -------------------------------------------------
	tlsLn, err := net.Listen("tcp", listenTLS)
	if err != nil {
		logger.Fatalf("fatal: listen on LISTEN_TLS=%q: %v", listenTLS, err)
	}

	cl := newChanListener(tlsLn.Addr())
	tlsSrv := &http.Server{
		Handler: a.routes(),
		// ReadHeaderTimeout bounds slowloris-style header dribbling without
		// cutting off long uploads (ReadTimeout stays 0, deliberately).
		ReadHeaderTimeout: 10 * time.Second,
		// IdleTimeout is long enough that a pooled CONNECT tunnel is not
		// re-handshaked mid-benchmark.
		IdleTimeout: 90 * time.Second,
		// WriteTimeout 0: a 64 MiB payload on a slow link must be allowed to
		// finish. ReadHeaderTimeout still bounds the header phase.
		WriteTimeout: 0,
		ReadTimeout:  0,
		ErrorLog:     log.New(os.Stdout, "iot-mock: http: ", log.LstdFlags|log.LUTC),
		ConnState: func(conn net.Conn, state http.ConnState) {
			switch state {
			case http.StateClosed, http.StateHijacked:
				if free, ok := activeConns.LoadAndDelete(conn); ok {
					free.(func())()
				}
			}
		},
	}

	// --- plain HTTP metrics listener ----------------------------------------
	metricsLn, err := net.Listen("tcp", listenMetrics)
	if err != nil {
		logger.Fatalf("fatal: listen on LISTEN_METRICS=%q: %v", listenMetrics, err)
	}
	metricsSrv := &http.Server{
		Handler:           metricsRoutes(a),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       90 * time.Second,
		ErrorLog:          log.New(os.Stdout, "iot-mock: http: ", log.LstdFlags|log.LUTC),
	}

	// --- startup log ---------------------------------------------------------
	logger.Printf("startup: mTLS listener on %s (TLS_CERT=%s TLS_KEY=%s, client certs required)",
		tlsLn.Addr(), certPath, keyPath)
	logger.Printf("startup: client CA %s", caPath)
	if caCert != nil {
		logger.Printf("startup: client CA subject CN=%q notAfter=%s",
			caCert.Subject.CommonName, caCert.NotAfter.UTC().Format(time.RFC3339))
	}
	if cert.Leaf != nil {
		logger.Printf("startup: server cert CN=%q leafNotAfter=%s",
			cert.Leaf.Subject.CommonName, cert.Leaf.NotAfter.UTC().Format(time.RFC3339))
	} else {
		logger.Printf("startup: server cert loaded (leaf not parsed)")
	}
	logger.Printf("startup: metrics listener on %s (GET /stats, GET /metrics, GET /health)",
		metricsLn.Addr())
	logger.Printf("startup: ALPN=HTTP/1.1 only; per-request logging disabled by design")

	// --- serve ---------------------------------------------------------------
	// Serve returns ErrServerClosed on Shutdown, which is not a failure, so
	// only an unexpected error is worth reporting.
	serveErr := make(chan error, 2)
	go func() {
		if err := tlsSrv.Serve(cl); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
		}
	}()
	go func() {
		if err := metricsSrv.Serve(metricsLn); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
		}
	}()
	go serveTLS(tlsLn, tlsCfg, cl, c, logger)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	select {
	case sig := <-sigCh:
		logger.Printf("shutdown: signal %s received, draining (timeout %s)", sig, shutdownTimeout)
	case err := <-serveErr:
		logger.Printf("fatal: server stopped unexpectedly: %v", err)
		os.Exit(1)
	}

	// Stop accepting new TCP connections first, then let in-flight requests
	// finish. The POC measures container stop times, so this must not hang.
	_ = tlsLn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	var wg sync.WaitGroup
	for _, srv := range []*http.Server{tlsSrv, metricsSrv} {
		wg.Add(1)
		go func(srv *http.Server) {
			defer wg.Done()
			if err := srv.Shutdown(ctx); err != nil {
				logger.Printf("shutdown: %v", err)
			}
		}(srv)
	}
	wg.Wait()

	s := c.snapshot()
	logger.Printf("shutdown: complete (connections_total=%d tls_handshakes_total=%d tls_handshake_failures_total=%d mtls_rejections_total=%d http_requests_total=%d)",
		s.ConnectionsTotal, s.TLSHandshakesTotal, s.TLSHandshakeFailuresTotal,
		s.MTLSRejectionsTotal, s.HTTPRequestsTotal)
	os.Exit(0)
}

// activeConns maps a connection handed to http.Server back to the function
// that decrements connections_active. It is keyed by the *tls.Conn itself,
// because http.Server must see the bare *tls.Conn for Request.TLS to be
// populated -- wrapping it would silently cost us the peer certificate.
var activeConns sync.Map

func metricsRoutes(a *app) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			notFound(w)
			return
		}
		body, err := json.MarshalIndent(a.c.snapshot(), "", "  ")
		if err != nil {
			http.Error(w, "encoding error", http.StatusInternalServerError)
			return
		}
		body = append(body, '\n')
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			notFound(w)
			return
		}
		body := a.c.prometheus()
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, body)
	})
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			notFound(w)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Length", "2")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok")
	})
	return mux
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
