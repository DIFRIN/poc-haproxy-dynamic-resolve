// Command client is the workload generator and test client for the
// poc-haproxy-dynamic-resolve POC.
//
// It has four modes, selected with -mode:
//
//	connect  IoT workload: HTTP CONNECT through the proxy, then end-to-end mTLS
//	         to the IoT Mock *inside* the tunnel.
//	tls      direct TLS to the proxy with a chosen SNI (TARGET architecture:
//	         SNI passthrough, no CONNECT), then end-to-end mTLS to the IoT Mock.
//
// The measured workload in both connect and tls mode is the request the real
// IoT devices accept: PUT <path> with a -body-bytes body (-method, -path,
// -body-bytes). GET /health is an infrastructure health probe and is never the
// measured workload.
//
//	dns      raw DNS load generator against one specific DNS server.
//	dnstest  a single DNS query, printing the outcome as JSON (functional tests).
//
// Standard library only: there are no module dependencies, so the image builds
// with zero downloads. The DNS packet encoder/decoder below is hand-rolled on
// purpose (header + question out; header + rcode + answers in) instead of
// pulling in a third-party DNS library.
//
// Output contract: the JSON summary is the LAST thing written to stdout, and it
// is a single pretty-printed object. All progress/diagnostics go to stderr.
// Exit code is 0 for any completed run, including runs where every single
// request failed (in a benchmark, failures are data). A non-zero exit means a
// configuration or setup error, never a request-level failure.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	mathrand "math/rand"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// exitConfig is the exit code for configuration/setup problems. Request-level
// failures never produce a non-zero exit.
const exitConfig = 2

// Defaults that differ per mode. The -timeout flag is shared, so 0 means
// "use the mode default".
const (
	connectDefaultTimeout = 5 * time.Second
	dnsDefaultTimeout     = 2 * time.Second
)

func main() {
	var (
		mode = flag.String("mode", "", "mode: connect | tls | dns | dnstest")

		// --- connect mode -------------------------------------------------
		proxy       = flag.String("proxy", "", "connect: proxy address CONNECT is sent to, e.g. 172.28.0.10:38888; tls: proxy address to open TLS to, e.g. 172.28.0.10:443 (required in both)")
		targetHost  = flag.String("target-host", "", "connect: CONNECT authority host; tls: the fixed identity to use when -servername is unset (default: one random name from the IoT namespace)")
		targetPort  = flag.Int("target-port", 443, "connect: CONNECT authority port")
		randomHost  = flag.Bool("random-host", false, "connect/tls: pick a fresh random iotNNNNNNN name for every request (forces DNS cache misses); ignored in tls mode when -servername is set")
		hostCount   = flag.Int("host-count", 1000000, "connect/tls/dns: size of the IoT namespace, iot0000001..iotNNNNNNN")
		duration    = flag.Duration("duration", 30*time.Second, "measurement duration; -warmup traffic runs first and is discarded")
		rps         = flag.Float64("rps", 0, "connect/tls: target requests/sec (0 = unlimited, closed loop)")
		concurrency = flag.Int("concurrency", 10, "number of parallel workers")
		persistent  = flag.Bool("persistent", false, "connect: each worker opens ONE CONNECT tunnel and reuses it (keep-alive)")
		reqPerTun   = flag.Int("requests-per-tunnel", 100, "connect: requests per tunnel when -persistent is set")
		clientCert  = flag.String("client-cert", "", "connect/tls: PEM client certificate; if empty NO client certificate is presented")
		clientKey   = flag.String("client-key", "", "connect/tls: PEM client private key")
		caFile      = flag.String("ca", "", "connect/tls: PEM CA bundle used to verify the server (default: system roots)")
		insecure    = flag.Bool("insecure-skip-verify", false, "connect/tls: skip server certificate verification (negative tests only)")
		servername  = flag.String("servername", "", "connect: TLS SNI override (default: the target host); tls: the SNI to send and verify against (default: the per-request identity)")
		warmup      = flag.Duration("warmup", 0, "run traffic for this long before measurement starts; stats are reset afterwards")
		outPath     = flag.String("out", "", "also write the JSON summary to this path")
		label       = flag.String("label", "", "free-form label echoed into the output")
		reqTimeout  = flag.Duration("timeout", 0, "per-request/query timeout (default 5s in connect/tls, 2s in dns/dnstest)")
		httpPath    = flag.String("path", "/", "connect/tls: HTTP path requested after the tunnel/handshake is established. The IoT devices accept any path; the name that matters is the SNI (tls) or the CONNECT authority (connect).")
		method      = flag.String("method", "PUT", "connect/tls: HTTP method for the measured workload request. The real IoT devices accept PUT; use GET only for the /health infrastructure probe, never as the measured workload.")
		bodyBytes   = flag.Int("body-bytes", 256, "connect/tls: size in bytes of the request body sent with the workload request (PUT). The filler is repeatable, so two runs of the same test put byte-identical payloads on the wire.")

		// --- dns / dnstest modes ------------------------------------------
		dnsServer = flag.String("server", "", "dns/dnstest: DNS server address, e.g. 172.28.0.31:5300 (required)")
		qps       = flag.Float64("qps", 0, "dns: target queries/sec (0 = unlimited, closed loop)")
		qtype     = flag.String("qtype", "A", "dns/dnstest: query type (A, AAAA, CNAME, NS, MX, TXT, SOA, PTR, SRV, ANY)")
		zone      = flag.String("zone", "test.domain", "connect/tls/dns: zone appended to generated iotNNNNNNN names")
		fixedName = flag.String("fixed-name", "", "dns: query this exact name instead of random iotNNNNNNN names")
		proto     = flag.String("proto", "udp", "dns/dnstest: udp or tcp")
		dnsName   = flag.String("name", "", "dnstest: the name to query (required)")
	)
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var err error
	switch *mode {
	case "connect":
		t := *reqTimeout
		if t <= 0 {
			t = connectDefaultTimeout
		}
		err = runConnect(ctx, &connectConfig{
			proxy: *proxy, targetHost: *targetHost, targetPort: *targetPort,
			randomHost: *randomHost, hostCount: *hostCount, zone: *zone,
			duration: *duration, rps: *rps, concurrency: *concurrency,
			persistent: *persistent, requestsPerTunnel: *reqPerTun,
			clientCert: *clientCert, clientKey: *clientKey, ca: *caFile,
			insecure: *insecure, servername: *servername,
			method: *method, path: *httpPath, bodyBytes: *bodyBytes,
			warmup: *warmup, out: *outPath, label: *label, timeout: t,
		})
	case "tls":
		t := *reqTimeout
		if t <= 0 {
			t = connectDefaultTimeout
		}
		err = runTLS(ctx, &tlsModeConfig{
			proxy: *proxy, servername: *servername, targetHost: *targetHost,
			randomHost: *randomHost, hostCount: *hostCount, zone: *zone,
			duration: *duration, rps: *rps, concurrency: *concurrency,
			clientCert: *clientCert, clientKey: *clientKey, ca: *caFile,
			insecure: *insecure, path: *httpPath,
			method: *method, bodyBytes: *bodyBytes,
			warmup: *warmup, out: *outPath, label: *label, timeout: t,
		})
	case "dns":
		t := *reqTimeout
		if t <= 0 {
			t = dnsDefaultTimeout
		}
		var qt uint16
		qt, err = parseQType(*qtype)
		if err == nil {
			err = runDNS(ctx, &dnsConfig{
				server: *dnsServer, duration: *duration, qps: *qps,
				concurrency: *concurrency, qtype: qt, qtypeName: strings.ToUpper(strings.TrimSpace(*qtype)),
				zone: *zone, hostCount: *hostCount, fixedName: *fixedName,
				proto: strings.ToLower(*proto), timeout: t,
				warmup: *warmup, out: *outPath, label: *label,
			})
		}
	case "dnstest":
		t := *reqTimeout
		if t <= 0 {
			t = dnsDefaultTimeout
		}
		var qt uint16
		qt, err = parseQType(*qtype)
		if err == nil {
			err = runDNSTest(*dnsServer, *dnsName, qt, strings.ToUpper(strings.TrimSpace(*qtype)), strings.ToLower(*proto), t)
		}
	case "":
		err = errors.New("-mode is required (connect | tls | dns | dnstest)")
	default:
		err = fmt.Errorf("unknown -mode %q (want connect | tls | dns | dnstest)", *mode)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "client: %v\n", err)
		os.Exit(exitConfig)
	}
}

// ---------------------------------------------------------------------------
// the measured workload request
// ---------------------------------------------------------------------------

// defaultBodyBytes is the body size of a workload request when -body-bytes is
// not given. It is small enough that the run measures the proxy path rather
// than the host's memory bandwidth.
const defaultBodyBytes = 256

// bodyPeriod is the period of the repeatable filler. Prime, so the pattern does
// not align with any buffer boundary the stack might use.
const bodyPeriod = 251

// repeatableBody returns n bytes of repeatable filler.
//
// Repeatability is the point: two runs of the same test must put byte-identical
// payloads on the wire, so a difference between two results cannot be a
// difference in what was sent. It follows the same rule as the IoT Mock's own
// /payload generator.
func repeatableBody(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(i % bodyPeriod)
	}
	return b
}

// methodHasBody reports whether a method carries a request body by definition,
// which decides whether Content-Length is sent even for a zero-length body.
func methodHasBody(method string) bool {
	switch method {
	case http.MethodPut, http.MethodPost, http.MethodPatch:
		return true
	}
	return false
}

// normalizeMethod upper-cases and validates -method. An empty value would
// produce a request line the server cannot parse, so it is refused here rather
// than surfacing later as a wall of http_error.
func normalizeMethod(m string) (string, error) {
	m = strings.ToUpper(strings.TrimSpace(m))
	if m == "" {
		return "", errors.New("-method must not be empty")
	}
	if strings.ContainsAny(m, " \t\r\n/") {
		return "", fmt.Errorf("-method %q contains an illegal character", m)
	}
	return m, nil
}

// normalizePath validates -path and returns it with a leading slash.
func normalizePath(p string) (string, error) {
	p = strings.TrimSpace(p)
	if p == "" {
		return "/", nil
	}
	if !strings.HasPrefix(p, "/") {
		return "", fmt.Errorf("-path %q must start with /", p)
	}
	return p, nil
}

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------

// progressLogger logs a one-line progress summary to stderr every interval.
// Never per request: that would distort the measurement it is reporting on.
func progressLogger(ctx context.Context, interval time.Duration, snapshot func() string) *sync.WaitGroup {
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				fmt.Fprintf(os.Stderr, "[client] %s\n", snapshot())
			}
		}
	}()
	return &wg
}

// latencySamples is a per-worker slice of latencies in milliseconds. Exact
// percentiles are computed at the end from the merged, sorted samples, so
// memory scales with the number of recorded samples (8 bytes each): a run of
// 10M samples holds roughly 80 MB. The sample count is reported in the output
// as latency_samples so that cost is always visible.
type latencySamples struct {
	ms []float64
}

func (l *latencySamples) add(d time.Duration) {
	l.ms = append(l.ms, float64(d.Nanoseconds())/1e6)
}

func mergeSamples(parts []latencySamples) []float64 {
	n := 0
	for _, p := range parts {
		n += len(p.ms)
	}
	all := make([]float64, 0, n)
	for _, p := range parts {
		all = append(all, p.ms...)
	}
	sort.Float64s(all)
	return all
}

func round3(f float64) float64 { return math.Round(f*1000) / 1000 }

// percentile uses the nearest-rank definition on the sorted sample set.
func percentile(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(p/100*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

type latencySummary struct {
	P50  float64 `json:"p50"`
	P90  float64 `json:"p90"`
	P95  float64 `json:"p95"`
	P99  float64 `json:"p99"`
	Max  float64 `json:"max"`
	Mean float64 `json:"mean"`
}

func summarize(sorted []float64) latencySummary {
	if len(sorted) == 0 {
		return latencySummary{}
	}
	var sum float64
	for _, v := range sorted {
		sum += v
	}
	return latencySummary{
		P50:  round3(percentile(sorted, 50)),
		P90:  round3(percentile(sorted, 90)),
		P95:  round3(percentile(sorted, 95)),
		P99:  round3(percentile(sorted, 99)),
		Max:  round3(sorted[len(sorted)-1]),
		Mean: round3(sum / float64(len(sorted))),
	}
}

// errorSamples keeps up to max distinct error strings for the summary.
type errorSamples struct {
	mu    sync.Mutex
	max   int
	seen  map[string]struct{}
	order []string
}

func newErrorSamples(max int) *errorSamples {
	return &errorSamples{max: max, seen: map[string]struct{}{}}
}

func (e *errorSamples) add(s string) {
	if s == "" {
		return
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if _, ok := e.seen[s]; ok {
		return
	}
	if len(e.order) >= e.max {
		return
	}
	e.seen[s] = struct{}{}
	e.order = append(e.order, s)
}

func (e *errorSamples) list() []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]string, len(e.order))
	copy(out, e.order)
	return out
}

func (e *errorSamples) merge(other *errorSamples) {
	for _, s := range other.list() {
		e.add(s)
	}
}

// pacer releases one token per request globally, so that the AGGREGATE rate
// (not the per-worker rate) approaches the target. rate <= 0 is closed loop.
type pacer struct {
	ticks <-chan time.Time
	stop  func()
}

func newPacer(rate float64) *pacer {
	if rate <= 0 {
		return &pacer{}
	}
	period := time.Duration(float64(time.Second) / rate)
	if period < time.Microsecond {
		period = time.Microsecond
	}
	t := time.NewTicker(period)
	return &pacer{ticks: t.C, stop: t.Stop}
}

func (p *pacer) wait(ctx context.Context) bool {
	if p.ticks == nil {
		return ctx.Err() == nil
	}
	select {
	case <-p.ticks:
		return true
	case <-ctx.Done():
		return false
	}
}

func writeSummary(out string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	if out != "" {
		return os.WriteFile(out, append(b, '\n'), 0o644)
	}
	return nil
}

func isTimeout(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) {
		return true
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return true
	}
	return strings.Contains(err.Error(), "i/o timeout")
}

// ---------------------------------------------------------------------------
// -mode=connect
// ---------------------------------------------------------------------------

type connectConfig struct {
	proxy      string
	targetHost string
	targetPort int
	randomHost bool
	hostCount  int
	// zone qualifies generated iotNNNNNNN names. Without it -random-host
	// emits a bare "iotNNNNNNN", which is not a name in any zone the POC
	// serves -- Squid then answers every request 503 ERR_DNS_FAIL and a
	// harness bug reads as a proxy failure.
	zone              string
	duration          time.Duration
	rps               float64
	concurrency       int
	persistent        bool
	requestsPerTunnel int
	clientCert        string
	clientKey         string
	ca                string
	insecure          bool
	servername        string
	warmup            time.Duration
	out               string
	label             string
	timeout           time.Duration

	// The measured workload request. method is the HTTP method the IoT devices
	// accept (PUT); path is validated at run time; body is the pre-built,
	// repeatable payload whose length is len(body).
	method    string
	path      string
	bodyBytes int
	body      []byte
}

// Outcome taxonomy. connect_rejected is deliberately NOT an error: for the
// security tests a correctly blocked CONNECT is the expected result.
const (
	outcomeSuccess         = "success"
	outcomeConnectRejected = "connect_rejected"
	outcomeConnectError    = "connect_error"
	outcomeTLSError        = "tls_error"
	outcomeMTLSRejected    = "mtls_rejected"
	outcomeHTTPError       = "http_error"
	outcomeTimeout         = "timeout"
)

type connectCounters struct {
	attempts        atomic.Int64
	success         atomic.Int64
	connectRejected atomic.Int64
	connectError    atomic.Int64
	tlsError        atomic.Int64
	mtlsRejected    atomic.Int64
	httpError       atomic.Int64
	timeout         atomic.Int64
	tunnelsOpened   atomic.Int64
}

type statusCodes struct {
	mu sync.Mutex
	m  map[int]int64
}

func newStatusCodes() *statusCodes { return &statusCodes{m: map[int]int64{}} }

func (s *statusCodes) add(code int) {
	s.mu.Lock()
	s.m[code]++
	s.mu.Unlock()
}

func (s *statusCodes) merge(other *statusCodes) {
	other.mu.Lock()
	defer other.mu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, v := range other.m {
		s.m[k] += v
	}
}

func (s *statusCodes) mapStringKeys() map[string]int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]int64, len(s.m))
	for k, v := range s.m {
		out[fmt.Sprintf("%d", k)] = v
	}
	return out
}

// countingConn counts raw bytes at the TCP layer (so TLS record overhead is
// included). That is the honest number for "what did this workload put on the
// wire", and it is what the benchmark reports as bytes_sent/bytes_received.
type countingConn struct {
	net.Conn
	sent *atomic.Int64
	recv *atomic.Int64
}

func (c *countingConn) Write(b []byte) (int, error) {
	n, err := c.Conn.Write(b)
	c.sent.Add(int64(n))
	return n, err
}

func (c *countingConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.recv.Add(int64(n))
	return n, err
}

// prefixConn serves already-buffered bytes before the socket. It exists only so
// that a CONNECT response read through bufio can never lose bytes that the
// following TLS handshake needs (in practice the server sends nothing after the
// CONNECT response until it sees the ClientHello, so the prefix is empty).
type prefixConn struct {
	net.Conn
	r io.Reader
}

func (c *prefixConn) Read(b []byte) (int, error) { return c.r.Read(b) }

// tlsErrorIsClientCertRejection reports whether a handshake failure is the
// server rejecting OUR client certificate (as opposed to us rejecting the
// server's certificate, or a protocol-level failure). A TLS alert arriving
// during the handshake was sent by the server, so certificate-related alerts
// mean exactly that: bad/unsupported/revoked/expired/unknown client cert, or
// "certificate required" when no client certificate was presented.
func tlsErrorIsClientCertRejection(err error) bool {
	var alert tls.AlertError
	if errors.As(err, &alert) {
		switch int(alert) {
		case 42, // bad_certificate
			43,  // unsupported_certificate
			44,  // certificate_revoked
			45,  // certificate_expired
			46,  // certificate_unknown
			48,  // unknown_ca
			116: // certificate_required
			return true
		}
	}
	// Fallback for wrapped/older error text: "remote error: tls: ..." is
	// explicitly the peer's alert, i.e. the server complaining about us.
	s := strings.ToLower(err.Error())
	if strings.Contains(s, "remote error: tls:") &&
		(strings.Contains(s, "certificate") || strings.Contains(s, "handshake failure")) {
		return true
	}
	return false
}

// classifyTLSErr maps any TLS-layer failure (handshake, or an alert that
// arrives after the handshake) onto the outcome taxonomy. Under TLS 1.3 the
// client's handshake can complete before the server's verdict arrives, so a
// rejected client certificate frequently surfaces on the first read/write
// rather than in HandshakeContext - both must classify identically.
func classifyTLSErr(err error) string {
	if isTimeout(err) {
		return outcomeTimeout
	}
	if tlsErrorIsClientCertRejection(err) {
		return outcomeMTLSRejected
	}
	return outcomeTLSError
}

type connectPhase struct {
	name    string
	dur     time.Duration
	collect bool
	ctr     *connectCounters
}

func runConnect(ctx context.Context, cfg *connectConfig) error {
	// ---- validate configuration ------------------------------------------
	if cfg.proxy == "" {
		return errors.New("-proxy is required in connect mode (e.g. 172.28.0.10:38888)")
	}
	if _, _, err := net.SplitHostPort(cfg.proxy); err != nil {
		return fmt.Errorf("-proxy %q is not host:port: %w", cfg.proxy, err)
	}
	if cfg.concurrency < 1 {
		return errors.New("-concurrency must be >= 1")
	}
	if cfg.duration <= 0 {
		return errors.New("-duration must be > 0")
	}
	if cfg.hostCount < 1 {
		return errors.New("-host-count must be >= 1")
	}
	if cfg.persistent && cfg.requestsPerTunnel < 1 {
		return errors.New("-requests-per-tunnel must be >= 1 with -persistent")
	}
	if (cfg.clientCert == "") != (cfg.clientKey == "") {
		return errors.New("-client-cert and -client-key must be given together")
	}

	// ---- the measured workload request -------------------------------------
	method, err := normalizeMethod(cfg.method)
	if err != nil {
		return err
	}
	cfg.method = method
	if cfg.path, err = normalizePath(cfg.path); err != nil {
		return err
	}
	if cfg.bodyBytes < 0 {
		return errors.New("-body-bytes must be >= 0")
	}
	cfg.body = repeatableBody(cfg.bodyBytes)

	// ---- TLS configuration ------------------------------------------------
	tlsCfg := &tls.Config{
		InsecureSkipVerify: cfg.insecure, // #nosec G402 - explicit negative-test flag
		MinVersion:         tls.VersionTLS12,
	}
	if cfg.ca != "" {
		pemBytes, err := os.ReadFile(cfg.ca)
		if err != nil {
			return fmt.Errorf("read -ca: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pemBytes) {
			return fmt.Errorf("-ca %s contains no usable PEM certificate", cfg.ca)
		}
		tlsCfg.RootCAs = pool
	}
	if cfg.clientCert != "" {
		pair, err := tls.LoadX509KeyPair(cfg.clientCert, cfg.clientKey)
		if err != nil {
			return fmt.Errorf("load client keypair: %w", err)
		}
		tlsCfg.Certificates = []tls.Certificate{pair}
	}
	// With no -client-cert we deliberately present no certificate at all, so a
	// server requiring mTLS must answer with "certificate required".

	// ---- target names ------------------------------------------------------
	nameRNG := mathrand.New(mathrand.NewSource(time.Now().UnixNano()))
	if cfg.zone == "" {
		cfg.zone = "test.domain"
	}
	cfg.zone = strings.TrimPrefix(strings.TrimSpace(cfg.zone), ".")
	if cfg.targetHost == "" {
		cfg.targetHost = randomIoTName(nameRNG, cfg.hostCount) + "." + cfg.zone
	}

	sniPolicy := cfg.servername
	if sniPolicy == "" {
		if cfg.randomHost {
			sniPolicy = "<per-request target host>"
		} else {
			sniPolicy = cfg.targetHost
		}
	}

	var (
		ctr     = &connectCounters{}
		discard = &connectCounters{}
		// Measurement-only aggregation. Warmup gets its own counters, status
		// code maps, error samples and byte counters, which are dropped.
		codes     = newStatusCodes()
		httpCodes = newStatusCodes()
		errs      = newErrorSamples(10)
		bytesSent int64
		bytesRecv int64
		startWall = time.Now().UTC()
	)

	latencyScope := fmt.Sprintf("persistent: per-request latency measured from just before the %s write on a reused tunnel (tunnel setup is counted separately and excluded)", cfg.method)
	if !cfg.persistent {
		latencyScope = fmt.Sprintf("short_lived: per-request latency measured from just before the CONNECT write to the last byte of the HTTP response (TCP+CONNECT+TLS+%s)", cfg.method)
	}

	logSnapshot := func() string {
		return fmt.Sprintf("attempts=%d success=%d rejected=%d connect_err=%d tls_err=%d mtls=%d http_err=%d timeout=%d",
			ctr.attempts.Load(), ctr.success.Load(), ctr.connectRejected.Load(),
			ctr.connectError.Load(), ctr.tlsError.Load(), ctr.mtlsRejected.Load(),
			ctr.httpError.Load(), ctr.timeout.Load())
	}

	// ---- run phases (warmup traffic is discarded, measurement follows) -----
	var phases []connectPhase
	if cfg.warmup > 0 {
		phases = append(phases, connectPhase{"warmup", cfg.warmup, false, discard})
	}
	phases = append(phases, connectPhase{"measure", cfg.duration, true, ctr})

	var allParts []latencySamples
	measuredStart, measuredEnd := time.Now(), time.Now()
	for _, ph := range phases {
		phaseCtx, cancel := context.WithTimeout(ctx, ph.dur)
		fmt.Fprintf(os.Stderr, "[client] phase %s: %s concurrency=%d target_rps=%.0f persistent=%v request=%s %s body=%dB proxy=%s\n",
			ph.name, ph.dur, cfg.concurrency, cfg.rps, cfg.persistent,
			cfg.method, cfg.path, len(cfg.body), cfg.proxy)
		if ph.collect {
			measuredStart = time.Now()
		}
		pl := progressLogger(phaseCtx, 10*time.Second, logSnapshot)
		res := runConnectPhase(phaseCtx, cfg, tlsCfg, ph.ctr, ph.collect)
		measuredEnd = time.Now()
		cancel()
		pl.Wait()
		if ph.collect {
			allParts = res.samples
			codes.merge(res.codes)
			httpCodes.merge(res.httpCodes)
			errs.merge(res.errs)
			bytesSent += res.bytesSent
			bytesRecv += res.bytesRecv
		}
	}
	if ctx.Err() != nil {
		measuredEnd = time.Now()
		fmt.Fprintln(os.Stderr, "[client] interrupted; reporting partial results")
	}

	sorted := mergeSamples(allParts)
	measuredSeconds := measuredEnd.Sub(measuredStart).Seconds()
	if measuredSeconds <= 0 {
		measuredSeconds = cfg.duration.Seconds()
	}
	achieved := float64(ctr.attempts.Load()) / measuredSeconds

	notes := []string{
		"connect_rejected means the proxy refused the CONNECT; the refusal status code is counted in connect_status_codes. It is an expected outcome for the security tests, not an error.",
		"latency_ms are exact percentiles (nearest-rank) over the merged, sorted per-worker samples; memory scales with sample count (8 bytes/sample, see latency_samples).",
		"bytes_sent/bytes_received are raw TCP bytes, so they include CONNECT framing and TLS record overhead.",
		"achieved_rps = attempts / measured_seconds (the actual measurement window, which may be shorter than -duration if interrupted).",
		"Request-level failures never change the exit code; exit 0 means the run completed.",
	}
	if cfg.persistent {
		notes = append(notes,
			fmt.Sprintf("persistent mode: tunnel setup failures (dial/CONNECT/TLS) are counted as their own attempt with the tunnel-setup outcome, so attempts may exceed the number of %s requests when the proxy or backend is unhealthy.", cfg.method),
			"persistent mode reuses one tunnel for many requests, so it measures the proxy's ability to carry requests on an established tunnel, not its tunnel setup rate.")
	}
	notes = append(notes, fmt.Sprintf("the measured workload request is %s %s with a %d-byte body, which is what the IoT devices accept. GET /health is an infrastructure probe and is never the measured workload.", cfg.method, cfg.path, len(cfg.body)))
	if cfg.warmup > 0 {
		notes = append(notes, "-warmup traffic runs BEFORE the measurement window, so total wall time is warmup_seconds + duration_seconds; warmup counters and latency samples were discarded.")
	}
	if cfg.clientCert == "" {
		notes = append(notes, "no client certificate was presented (-client-cert empty); a server requiring mTLS should answer mtls_rejected.")
	}
	if cfg.insecure {
		notes = append(notes, "-insecure-skip-verify was set: server certificate verification was disabled.")
	}

	sum := map[string]any{
		"label":                cfg.label,
		"mode":                 "connect",
		"start_time":           startWall.Format(time.RFC3339),
		"duration_seconds":     cfg.duration.Seconds(),
		"measured_seconds":     round3(measuredSeconds),
		"warmup_seconds":       cfg.warmup.Seconds(),
		"target_rps":           cfg.rps,
		"concurrency":          cfg.concurrency,
		"persistent":           cfg.persistent,
		"requests_per_tunnel":  cfg.requestsPerTunnel,
		"proxy":                cfg.proxy,
		"target_host":          cfg.targetHost,
		"random_host":          cfg.randomHost,
		"host_count":           cfg.hostCount,
		"target_port":          cfg.targetPort,
		"method":               cfg.method,
		"path":                 cfg.path,
		"body_bytes":           len(cfg.body),
		"servername":           sniPolicy,
		"client_cert":          cfg.clientCert,
		"insecure_skip_verify": cfg.insecure,
		"latency_scope":        latencyScope,
		"attempts":             ctr.attempts.Load(),
		"success":              ctr.success.Load(),
		"connect_rejected":     ctr.connectRejected.Load(),
		"connect_error":        ctr.connectError.Load(),
		"tls_error":            ctr.tlsError.Load(),
		"mtls_rejected":        ctr.mtlsRejected.Load(),
		"http_error":           ctr.httpError.Load(),
		"timeout":              ctr.timeout.Load(),
		"tunnels_opened":       ctr.tunnelsOpened.Load(),
		"achieved_rps":         round3(achieved),
		"latency_ms":           summarize(sorted),
		"latency_samples":      len(sorted),
		"connect_status_codes": codes.mapStringKeys(),
		"http_status_codes":    httpCodes.mapStringKeys(),
		"bytes_sent":           bytesSent,
		"bytes_received":       bytesRecv,
		"errors_sample":        errs.list(),
		"notes":                notes,
	}
	return writeSummary(cfg.out, sum)
}

func randomIoTName(rng *mathrand.Rand, hostCount int) string {
	return fmt.Sprintf("iot%07d", rng.Intn(hostCount)+1)
}

type connectPhaseIO struct {
	cfg       *connectConfig
	tlsCfg    *tls.Config
	ctr       *connectCounters
	codes     *statusCodes
	httpCodes *statusCodes
	errs      *errorSamples
	bytesSent *atomic.Int64
	bytesRecv *atomic.Int64
}

// connectPhaseResult is one phase's local result set: it is merged into the
// summary only when the phase is the measurement phase.
type connectPhaseResult struct {
	samples   []latencySamples
	codes     *statusCodes
	httpCodes *statusCodes
	errs      *errorSamples
	bytesSent int64
	bytesRecv int64
}

func runConnectPhase(ctx context.Context, cfg *connectConfig, tlsCfg *tls.Config, ctr *connectCounters, collect bool) *connectPhaseResult {
	p := newPacer(cfg.rps)
	if p.stop != nil {
		defer p.stop()
	}
	var sent, recv atomic.Int64
	res := &connectPhaseResult{
		samples:   make([]latencySamples, cfg.concurrency),
		codes:     newStatusCodes(),
		httpCodes: newStatusCodes(),
		errs:      newErrorSamples(10),
	}
	var wg sync.WaitGroup
	for w := 0; w < cfg.concurrency; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			ph := &connectPhaseIO{cfg: cfg, tlsCfg: tlsCfg, ctr: ctr, codes: res.codes, httpCodes: res.httpCodes, errs: res.errs, bytesSent: &sent, bytesRecv: &recv}
			rng := mathrand.New(mathrand.NewSource(time.Now().UnixNano() + int64(w)*7919))
			var samples latencySamples
			if cfg.persistent {
				ph.workerPersistent(ctx, p, rng, collect, &samples)
			} else {
				ph.workerShortLived(ctx, p, rng, collect, &samples)
			}
			res.samples[w] = samples
		}(w)
	}
	wg.Wait()
	res.bytesSent = sent.Load()
	res.bytesRecv = recv.Load()
	return res
}

// record classifies and counts one attempt.
func (ph *connectPhaseIO) record(outcome string, status int, err error, d time.Duration, samples *latencySamples, collect bool) {
	ph.ctr.attempts.Add(1)
	switch outcome {
	case outcomeSuccess:
		ph.ctr.success.Add(1)
	case outcomeConnectRejected:
		ph.ctr.connectRejected.Add(1)
	case outcomeConnectError:
		ph.ctr.connectError.Add(1)
	case outcomeTLSError:
		ph.ctr.tlsError.Add(1)
	case outcomeMTLSRejected:
		ph.ctr.mtlsRejected.Add(1)
	case outcomeHTTPError:
		ph.ctr.httpError.Add(1)
	case outcomeTimeout:
		ph.ctr.timeout.Add(1)
	}
	if status > 0 && outcome != outcomeConnectRejected {
		// CONNECT status codes are counted where the CONNECT response is read.
		ph.httpCodes.add(status)
	}
	if err != nil {
		ph.errs.add(fmt.Sprintf("%s: %v", outcome, err))
	}
	// A rejected CONNECT never reaches a request, so it has no meaningful
	// request latency: it is counted, not timed.
	if collect && outcome != outcomeConnectRejected {
		samples.add(d)
	}
}

type tunnel struct {
	conn net.Conn
	tls  *tls.Conn
	br   *bufio.Reader
}

func (t *tunnel) close() {
	if t == nil {
		return
	}
	if t.tls != nil {
		_ = t.tls.Close()
		return
	}
	if t.conn != nil {
		_ = t.conn.Close()
	}
}

func (ph *connectPhaseIO) deadlineFor(ctx context.Context) time.Time {
	dl := time.Now().Add(ph.cfg.timeout)
	if cd, ok := ctx.Deadline(); ok && cd.Before(dl) {
		dl = cd
	}
	return dl
}

func (ph *connectPhaseIO) servernameFor(host string) string {
	if ph.cfg.servername != "" {
		return ph.cfg.servername
	}
	return host
}

// openTunnel performs steps 1-4: TCP connect, CONNECT exchange, TLS handshake.
// It returns (nil, outcome, statusCode, err) on failure.
func (ph *connectPhaseIO) openTunnel(ctx context.Context, host string) (*tunnel, string, int, error) {
	dl := ph.deadlineFor(ctx)
	authority := fmt.Sprintf("%s:%d", host, ph.cfg.targetPort)

	d := net.Dialer{Deadline: dl}
	raw, err := d.DialContext(ctx, "tcp", ph.cfg.proxy)
	if err != nil {
		if isTimeout(err) {
			return nil, outcomeTimeout, 0, err
		}
		return nil, outcomeConnectError, 0, err
	}
	cc := &countingConn{Conn: raw, sent: ph.bytesSent, recv: ph.bytesRecv}
	ok := false
	defer func() {
		if !ok {
			_ = raw.Close()
		}
	}()
	_ = raw.SetDeadline(dl)

	// Step 2: CONNECT.
	req := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", authority, authority)
	if _, err := cc.Write([]byte(req)); err != nil {
		return nil, classifyNetIO(err), 0, err
	}

	// Step 3: status line + headers.
	br := bufio.NewReader(cc)
	line, err := br.ReadString('\n')
	if err != nil {
		return nil, classifyNetIO(err), 0, err
	}
	code, err := parseStatusCode(line)
	if err != nil {
		return nil, outcomeConnectError, 0, fmt.Errorf("bad CONNECT response %q: %w", strings.TrimSpace(line), err)
	}
	ph.codes.add(code) // every CONNECT status code is recorded, 200 included
	if code != 200 {
		// Correctly blocked CONNECT: an expected outcome, not an error.
		return nil, outcomeConnectRejected, code, nil
	}
	// Consume the rest of the CONNECT header block before the tunnel becomes
	// an opaque byte stream.
	for {
		l, err := br.ReadString('\n')
		if err != nil {
			return nil, classifyNetIO(err), 0, err
		}
		if l == "\r\n" || l == "\n" {
			break
		}
	}

	// Step 4: TLS over the tunnel (end-to-end mTLS with the IoT Mock).
	var under net.Conn = cc
	if n := br.Buffered(); n > 0 {
		peek, _ := br.Peek(n)
		under = &prefixConn{Conn: cc, r: io.MultiReader(bytes.NewReader(peek), cc)}
	}
	tlsConf := ph.tlsCfg.Clone()
	tlsConf.ServerName = ph.servernameFor(host)
	tlsConf.NextProtos = []string{"http/1.1"}
	tc := tls.Client(under, tlsConf)
	if err := tc.HandshakeContext(ctx); err != nil {
		return nil, classifyTLSErr(err), 0, err
	}
	ok = true
	ph.ctr.tunnelsOpened.Add(1)
	return &tunnel{conn: raw, tls: tc, br: bufio.NewReader(tc)}, "", 0, nil
}

func classifyNetIO(err error) string {
	if isTimeout(err) {
		return outcomeTimeout
	}
	return outcomeConnectError
}

func parseStatusCode(line string) (int, error) {
	parts := strings.Fields(strings.TrimSpace(line))
	if len(parts) < 2 || !strings.HasPrefix(parts[0], "HTTP/") {
		return 0, errors.New("not an HTTP status line")
	}
	var code int
	if _, err := fmt.Sscanf(parts[1], "%d", &code); err != nil {
		return 0, fmt.Errorf("unparsable status code %q", parts[1])
	}
	return code, nil
}

// doRequest performs step 5/6: one workload request inside the tunnel -- by
// default PUT <path> with a -body-bytes body, which is what the real IoT
// devices accept. keepAlive selects the Connection header. It returns the
// status code, whether the tunnel is still reusable, and any error.
func (ph *connectPhaseIO) doRequest(ctx context.Context, t *tunnel, host string, keepAlive bool) (int, bool, error) {
	_ = t.conn.SetDeadline(ph.deadlineFor(ctx))

	connHdr := "close"
	if keepAlive {
		connHdr = "keep-alive"
	}
	hdr := fmt.Sprintf("%s %s HTTP/1.1\r\nHost: %s\r\nConnection: %s\r\n",
		ph.cfg.method, ph.cfg.path, ph.servernameFor(host), connHdr)
	if methodHasBody(ph.cfg.method) || len(ph.cfg.body) > 0 {
		// Explicit framing: without Content-Length the server cannot know
		// where the body ends, and a reused tunnel would desynchronise.
		hdr += fmt.Sprintf("Content-Length: %d\r\n", len(ph.cfg.body))
	}
	hdr += "\r\n"

	// Header and body go out in ONE write, so the request is a single TLS
	// record. Two writes would double the record count on the measured path
	// and charge the benchmark for an artefact of how the client is coded.
	req := make([]byte, 0, len(hdr)+len(ph.cfg.body))
	req = append(req, hdr...)
	req = append(req, ph.cfg.body...)
	if _, err := t.tls.Write(req); err != nil {
		return 0, false, err
	}
	resp, err := http.ReadResponse(t.br, &http.Request{Method: ph.cfg.method})
	if err != nil {
		return 0, false, err
	}
	_, cerr := io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	if cerr != nil {
		return resp.StatusCode, false, cerr
	}
	reusable := keepAlive && !resp.Close && (resp.ContentLength >= 0 || len(resp.TransferEncoding) > 0)
	return resp.StatusCode, reusable, nil
}

// workerShortLived: one CONNECT tunnel per request, closed afterwards.
func (ph *connectPhaseIO) workerShortLived(ctx context.Context, p *pacer, rng *mathrand.Rand, collect bool, samples *latencySamples) {
	for ctx.Err() == nil {
		if !p.wait(ctx) {
			return
		}
		host := ph.nextHost(rng)
		start := time.Now()
		t, outcome, status, err := ph.openTunnel(ctx, host)
		if t == nil {
			ph.record(outcome, status, err, time.Since(start), samples, collect)
			continue
		}
		st, _, rerr := ph.doRequest(ctx, t, host, false)
		lat := time.Since(start)
		t.close()
		if rerr != nil {
			ph.record(classifyAfterHandshake(rerr), st, rerr, lat, samples, collect)
			continue
		}
		if st >= 400 {
			ph.record(outcomeHTTPError, st, nil, lat, samples, collect)
			continue
		}
		ph.record(outcomeSuccess, st, nil, lat, samples, collect)
	}
}

// workerPersistent: one CONNECT tunnel reused for -requests-per-tunnel requests
// before being replaced. Tunnel setup is counted as its own attempt so that
// setup failures still appear in the taxonomy, and its cost is NOT included in
// the per-request latency (which is measured from just before the GET write).
func (ph *connectPhaseIO) workerPersistent(ctx context.Context, p *pacer, rng *mathrand.Rand, collect bool, samples *latencySamples) {
	for ctx.Err() == nil {
		host := ph.nextHost(rng)
		t, outcome, status, err := ph.openTunnel(ctx, host)
		if t == nil {
			ph.record(outcome, status, err, 0, samples, false)
			continue
		}
		for i := 0; i < ph.cfg.requestsPerTunnel; i++ {
			if !p.wait(ctx) {
				t.close()
				return
			}
			start := time.Now()
			st, reusable, rerr := ph.doRequest(ctx, t, host, true)
			lat := time.Since(start)
			if rerr != nil {
				ph.record(classifyAfterHandshake(rerr), st, rerr, lat, samples, collect)
				break
			}
			if st >= 400 {
				ph.record(outcomeHTTPError, st, nil, lat, samples, collect)
			} else {
				ph.record(outcomeSuccess, st, nil, lat, samples, collect)
			}
			if !reusable {
				break
			}
		}
		t.close()
	}
}

// classifyAfterHandshake maps an error raised after the TLS handshake returned,
// i.e. while sending or reading the HTTP request. That is where a TLS 1.3
// mTLS rejection lands (see classifyTLSErr), so certificate alerts must be
// attributed here too, not only in HandshakeContext.
func classifyAfterHandshake(err error) string {
	if isTimeout(err) {
		return outcomeTimeout
	}
	if tlsErrorIsClientCertRejection(err) {
		return outcomeMTLSRejected
	}
	if strings.Contains(err.Error(), "tls:") {
		return outcomeTLSError
	}
	return outcomeHTTPError
}

func (ph *connectPhaseIO) nextHost(rng *mathrand.Rand) string {
	if ph.cfg.randomHost {
		return randomIoTName(rng, ph.cfg.hostCount) + "." + ph.cfg.zone
	}
	return ph.cfg.targetHost
}

// ---------------------------------------------------------------------------
// -mode=tls
//
// DIRECT TLS to the proxy with a chosen SNI. There is no CONNECT: the client
// opens a TLS session straight to the VIP and the proxy routes on the SNI
// inside the ClientHello without terminating TLS. This is how the TARGET
// architecture (SNI passthrough, ADR 0012) is exercised.
//
// TARGET REJECTION IS NOT AN HTTP STATUS.
// A TCP-mode proxy has no status line to send, so it refuses a bad destination
// by closing the connection. A destination-policy rejection therefore surfaces
// here as a TLS handshake failure -- a clean EOF, or a reset -- and is
// classified tls_error, with the raw error string preserved in errors_sample.
// That is the *expected* result for the SSRF corpus, not a bug: see the
// security tests, where a refused connection is a PASS.
//
// mTLS rejection by the IoT Mock also arrives as a TLS alert, so it must be
// separated from a policy rejection. That is done with the same classifier the
// connect mode uses (tlsErrorIsClientCertRejection / classifyTLSErr), which
// reads the alert number rather than the human-readable string.
//
// Because TLS 1.3 completes the client handshake before the server's verdict on
// the client certificate arrives, a rejected certificate frequently surfaces on
// the first read instead of in HandshakeContext. classifyAfterHandshake covers
// that path, exactly as in connect mode.
// ---------------------------------------------------------------------------

type tlsModeConfig struct {
	proxy       string
	servername  string
	targetHost  string
	randomHost  bool
	hostCount   int
	zone        string
	duration    time.Duration
	rps         float64
	concurrency int
	clientCert  string
	clientKey   string
	ca          string
	insecure    bool
	path        string
	method      string
	bodyBytes   int
	body        []byte
	warmup      time.Duration
	out         string
	label       string
	timeout     time.Duration
}

type tlsModeCounters struct {
	attempts      atomic.Int64
	success       atomic.Int64
	connectError  atomic.Int64
	tlsError      atomic.Int64
	mtlsRejected  atomic.Int64
	httpError     atomic.Int64
	timeout       atomic.Int64
	handshakes    atomic.Int64
	identityCheck atomic.Int64
	identityBad   atomic.Int64
}

// tlsOutcome is one request's recorded evidence. It is kept for a bounded
// number of requests per phase so that the security tests can read back the
// exact failure string and the identity the server actually saw, rather than
// only an aggregate count.
type tlsOutcome struct {
	Name      string  `json:"name"`
	SNI       string  `json:"sni,omitempty"`
	Peer      string  `json:"peer,omitempty"`
	Status    int     `json:"status"`
	Outcome   string  `json:"outcome"`
	LatencyMS float64 `json:"latency_ms"`
	Body      string  `json:"body,omitempty"`
	Error     string  `json:"error,omitempty"`
}

type tlsOutcomeStore struct {
	mu   sync.Mutex
	max  int
	list []tlsOutcome
}

func (s *tlsOutcomeStore) add(o tlsOutcome) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.list) >= s.max {
		return
	}
	s.list = append(s.list, o)
}

func (s *tlsOutcomeStore) samples() []tlsOutcome {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]tlsOutcome, len(s.list))
	copy(out, s.list)
	return out
}

// identityBody is the JSON shape of the IoT Mock's GET / identity endpoint.
// Only `sni` is consumed: it is the SNI the *server* observed, which is what
// makes it evidence that the proxy tunneled the name the client asked for
// rather than something it substituted.
type identityBody struct {
	SNI  string `json:"sni"`
	Peer string `json:"peer"`
}

type tlsPhaseIO struct {
	cfg       *tlsModeConfig
	tlsCfg    *tls.Config
	ctr       *tlsModeCounters
	httpCodes *statusCodes
	errs      *errorSamples
	evidence  *tlsOutcomeStore
	bytesSent *atomic.Int64
	bytesRecv *atomic.Int64
}

func runTLS(ctx context.Context, cfg *tlsModeConfig) error {
	// ---- validate configuration ------------------------------------------
	if cfg.proxy == "" {
		return errors.New("-proxy is required in tls mode (e.g. 172.28.0.10:443)")
	}
	if _, _, err := net.SplitHostPort(cfg.proxy); err != nil {
		return fmt.Errorf("-proxy %q is not host:port: %w", cfg.proxy, err)
	}
	if cfg.concurrency < 1 {
		return errors.New("-concurrency must be >= 1")
	}
	if cfg.duration <= 0 {
		return errors.New("-duration must be > 0")
	}
	if cfg.hostCount < 1 {
		return errors.New("-host-count must be >= 1")
	}
	if (cfg.clientCert == "") != (cfg.clientKey == "") {
		return errors.New("-client-cert and -client-key must be given together")
	}

	// ---- the measured workload request -------------------------------------
	// Identical to connect mode: the two architectures must be compared on the
	// same request, or the comparison is between two different workloads.
	method, err := normalizeMethod(cfg.method)
	if err != nil {
		return err
	}
	cfg.method = method
	if cfg.path, err = normalizePath(cfg.path); err != nil {
		return err
	}
	if cfg.bodyBytes < 0 {
		return errors.New("-body-bytes must be >= 0")
	}
	cfg.body = repeatableBody(cfg.bodyBytes)

	// ---- TLS configuration ------------------------------------------------
	// ClientSessionCache is left nil (the default): session resumption would
	// let a cached session bypass a fresh handshake, which would hide exactly
	// the certificate rejections the negative tests are looking for.
	tlsCfg := &tls.Config{
		InsecureSkipVerify: cfg.insecure, // #nosec G402 - explicit negative-test flag
		MinVersion:         tls.VersionTLS12,
	}
	if cfg.ca != "" {
		pemBytes, err := os.ReadFile(cfg.ca)
		if err != nil {
			return fmt.Errorf("read -ca: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pemBytes) {
			return fmt.Errorf("-ca %s contains no usable PEM certificate", cfg.ca)
		}
		tlsCfg.RootCAs = pool
	}
	if cfg.clientCert != "" {
		pair, err := tls.LoadX509KeyPair(cfg.clientCert, cfg.clientKey)
		if err != nil {
			return fmt.Errorf("load client keypair: %w", err)
		}
		tlsCfg.Certificates = []tls.Certificate{pair}
	}
	// With no -client-cert no certificate is presented at all, so an
	// mTLS-enforcing server must answer with "certificate required".

	// ---- the identity used when nothing pins it ---------------------------
	// The identity must be fully qualified: the SNI is the name the proxy
	// resolves, so a bare "iot0000123" would resolve nowhere. connect mode
	// leaves the qualification to the caller's -target-host; here the zone
	// (-zone, shared with dns mode) is applied to every generated name.
	if cfg.zone == "" {
		cfg.zone = "test.domain"
	}
	cfg.zone = strings.TrimPrefix(strings.TrimSpace(cfg.zone), ".")
	nameRNG := mathrand.New(mathrand.NewSource(time.Now().UnixNano()))
	if cfg.targetHost == "" && cfg.servername == "" {
		cfg.targetHost = cfg.qualifiedRandomName(nameRNG)
	}

	var identityPolicy string
	switch {
	case cfg.servername != "":
		identityPolicy = cfg.servername + " (pinned by -servername)"
	case cfg.randomHost:
		identityPolicy = "<one random iotNNNNNNN name per request>"
	default:
		identityPolicy = cfg.targetHost
	}

	var (
		ctr       = &tlsModeCounters{}
		discard   = &tlsModeCounters{}
		httpCodes = newStatusCodes()
		errs      = newErrorSamples(10)
		evid      = &tlsOutcomeStore{max: 10}
		bytesSent int64
		bytesRecv int64
		startWall = time.Now().UTC()
	)

	logSnapshot := func() string {
		return fmt.Sprintf("attempts=%d success=%d connect_err=%d tls_err=%d mtls=%d http_err=%d timeout=%d",
			ctr.attempts.Load(), ctr.success.Load(), ctr.connectError.Load(),
			ctr.tlsError.Load(), ctr.mtlsRejected.Load(), ctr.httpError.Load(), ctr.timeout.Load())
	}

	type phase struct {
		name    string
		dur     time.Duration
		collect bool
		ctr     *tlsModeCounters
	}
	var phases []phase
	if cfg.warmup > 0 {
		phases = append(phases, phase{"warmup", cfg.warmup, false, discard})
	}
	phases = append(phases, phase{"measure", cfg.duration, true, ctr})

	var allParts []latencySamples
	measuredStart, measuredEnd := time.Now(), time.Now()
	for _, ph := range phases {
		phaseCtx, cancel := context.WithTimeout(ctx, ph.dur)
		fmt.Fprintf(os.Stderr, "[client] phase %s: %s concurrency=%d target_rps=%.0f sni=%s request=%s %s body=%dB proxy=%s\n",
			ph.name, ph.dur, cfg.concurrency, cfg.rps, identityPolicy,
			cfg.method, cfg.path, len(cfg.body), cfg.proxy)
		if ph.collect {
			measuredStart = time.Now()
		}
		pl := progressLogger(phaseCtx, 10*time.Second, logSnapshot)
		res := runTLSPhase(phaseCtx, cfg, tlsCfg, ph.ctr, ph.collect, evid)
		measuredEnd = time.Now()
		cancel()
		pl.Wait()
		if ph.collect {
			allParts = res.samples
			httpCodes.merge(res.httpCodes)
			errs.merge(res.errs)
			bytesSent += res.bytesSent
			bytesRecv += res.bytesRecv
		}
	}
	if ctx.Err() != nil {
		measuredEnd = time.Now()
		fmt.Fprintln(os.Stderr, "[client] interrupted; reporting partial results")
	}

	sorted := mergeSamples(allParts)
	measuredSeconds := measuredEnd.Sub(measuredStart).Seconds()
	if measuredSeconds <= 0 {
		measuredSeconds = cfg.duration.Seconds()
	}

	notes := []string{
		"DIRECT TLS, no CONNECT: this mode exercises the TARGET architecture (SNI passthrough, ADR 0012). The proxy reads the SNI without terminating TLS, resolves it, validates the RESOLVED address, and tunnels raw TLS to the IoT Mock.",
		"TARGET refuses a bad destination by CLOSING THE TCP CONNECTION -- TCP mode has no HTTP status to send. A destination-policy rejection therefore appears as tls_error with an EOF/reset error string, never as an HTTP status. For the security corpus this is the expected (passing) result.",
		"mtls_rejected is reserved for a TLS alert sent by the IoT Mock about OUR client certificate (missing, expired, untrusted). It is distinguished from tls_error by the TLS alert number, not by string matching.",
		"latency_ms covers EVERY attempt including refused ones: for the security corpus the elapsed time to the refusal is itself the measurement.",
		"identity_checked/identity_mismatch compare the `sni` field in the IoT Mock's response against the name this client actually requested. The device-facing PUT response carries that field on every successful request, so the identity check is active for the measured workload itself, not only for GET /.",
		"achieved_rps = attempts / measured_seconds (the actual measurement window, which may be shorter than -duration if interrupted).",
		"Request-level failures never change the exit code; exit 0 means the run completed.",
		fmt.Sprintf("the measured workload request is %s %s with a %d-byte body, which is what the IoT devices accept. GET /health is an infrastructure probe and is never the measured workload.", cfg.method, cfg.path, len(cfg.body)),
	}
	if cfg.insecure {
		notes = append(notes, "-insecure-skip-verify was set: server certificate verification was disabled.")
	}
	if cfg.clientCert == "" {
		notes = append(notes, "no client certificate was presented (-client-cert empty); a server requiring mTLS should answer mtls_rejected.")
	}

	sum := map[string]any{
		"label":                cfg.label,
		"mode":                 "tls",
		"start_time":           startWall.Format(time.RFC3339),
		"duration_seconds":     cfg.duration.Seconds(),
		"measured_seconds":     round3(measuredSeconds),
		"warmup_seconds":       cfg.warmup.Seconds(),
		"target_rps":           cfg.rps,
		"concurrency":          cfg.concurrency,
		"proxy":                cfg.proxy,
		"method":               cfg.method,
		"path":                 cfg.path,
		"body_bytes":           len(cfg.body),
		"servername":           identityPolicy,
		"random_host":          cfg.randomHost,
		"host_count":           cfg.hostCount,
		"zone":                 cfg.zone,
		"client_cert":          cfg.clientCert,
		"insecure_skip_verify": cfg.insecure,
		"latency_scope":        fmt.Sprintf("per request: from just before the TCP connect to the last byte of the HTTP response (TCP+TLS+%s); refused attempts are timed up to the refusal", cfg.method),
		"attempts":             ctr.attempts.Load(),
		"success":              ctr.success.Load(),
		"connect_error":        ctr.connectError.Load(),
		"tls_error":            ctr.tlsError.Load(),
		"mtls_rejected":        ctr.mtlsRejected.Load(),
		"http_error":           ctr.httpError.Load(),
		"timeout":              ctr.timeout.Load(),
		"handshakes_completed": ctr.handshakes.Load(),
		"identity_checked":     ctr.identityCheck.Load(),
		"identity_mismatch":    ctr.identityBad.Load(),
		"achieved_rps":         round3(float64(ctr.attempts.Load()) / measuredSeconds),
		"latency_ms":           summarize(sorted),
		"latency_samples":      len(sorted),
		"http_status_codes":    httpCodes.mapStringKeys(),
		"bytes_sent":           bytesSent,
		"bytes_received":       bytesRecv,
		"outcomes_sample":      evid.samples(),
		"errors_sample":        errs.list(),
		"notes":                notes,
	}
	return writeSummary(cfg.out, sum)
}

type tlsPhaseResult struct {
	samples   []latencySamples
	httpCodes *statusCodes
	errs      *errorSamples
	bytesSent int64
	bytesRecv int64
}

func runTLSPhase(ctx context.Context, cfg *tlsModeConfig, tlsCfg *tls.Config, ctr *tlsModeCounters, collect bool, evid *tlsOutcomeStore) *tlsPhaseResult {
	p := newPacer(cfg.rps)
	if p.stop != nil {
		defer p.stop()
	}
	var sent, recv atomic.Int64
	res := &tlsPhaseResult{
		samples:   make([]latencySamples, cfg.concurrency),
		httpCodes: newStatusCodes(),
		errs:      newErrorSamples(10),
	}
	var wg sync.WaitGroup
	for w := 0; w < cfg.concurrency; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			ph := &tlsPhaseIO{
				cfg: cfg, tlsCfg: tlsCfg, ctr: ctr, httpCodes: res.httpCodes,
				errs: res.errs, evidence: evid, bytesSent: &sent, bytesRecv: &recv,
			}
			rng := mathrand.New(mathrand.NewSource(time.Now().UnixNano() + int64(w)*7919))
			var samples latencySamples
			ph.worker(ctx, p, rng, collect, &samples)
			res.samples[w] = samples
		}(w)
	}
	wg.Wait()
	res.bytesSent = sent.Load()
	res.bytesRecv = recv.Load()
	return res
}

func (ph *tlsPhaseIO) deadlineFor(ctx context.Context) time.Time {
	dl := time.Now().Add(ph.cfg.timeout)
	if cd, ok := ctx.Deadline(); ok && cd.Before(dl) {
		dl = cd
	}
	return dl
}

// nextName returns the identity for one request: the SNI to send, the Host
// header, and the name the identity check expects the server to report back.
// A pinned -servername wins over -random-host, because it is the explicit
// instruction.
func (ph *tlsPhaseIO) nextName(rng *mathrand.Rand) string {
	if ph.cfg.servername != "" {
		return ph.cfg.servername
	}
	if ph.cfg.randomHost {
		return ph.cfg.qualifiedRandomName(rng)
	}
	return ph.cfg.targetHost
}

// qualifiedRandomName returns a fresh iotNNNNNNN.<zone> identity.
func (cfg *tlsModeConfig) qualifiedRandomName(rng *mathrand.Rand) string {
	return randomIoTName(rng, cfg.hostCount) + "." + cfg.zone
}

func (ph *tlsPhaseIO) record(outcome string, status int, name string, o tlsOutcome, err error, d time.Duration, samples *latencySamples, collect bool) {
	ph.ctr.attempts.Add(1)
	switch outcome {
	case outcomeSuccess:
		ph.ctr.success.Add(1)
	case outcomeConnectError:
		ph.ctr.connectError.Add(1)
	case outcomeTLSError:
		ph.ctr.tlsError.Add(1)
	case outcomeMTLSRejected:
		ph.ctr.mtlsRejected.Add(1)
	case outcomeHTTPError:
		ph.ctr.httpError.Add(1)
	case outcomeTimeout:
		ph.ctr.timeout.Add(1)
	}
	if status > 0 {
		ph.httpCodes.add(status)
	}
	if err != nil {
		ph.errs.add(fmt.Sprintf("%s: %v", outcome, err))
	}
	o.Name = name
	o.Outcome = outcome
	o.Status = status
	o.LatencyMS = round3(float64(d.Nanoseconds()) / 1e6)
	if err != nil {
		o.Error = err.Error()
	}
	ph.evidence.add(o)
	// Every attempt is timed, refused ones included: for the security corpus
	// the elapsed time to the refusal is a result, not noise.
	if collect {
		samples.add(d)
	}
}

// oneRequest performs TCP connect, TLS handshake, and one workload request, in
// that order, and classifies the outcome. It never returns a partial success:
// on any failure the outcome string and raw error are what the caller records.
func (ph *tlsPhaseIO) oneRequest(ctx context.Context, name string) (int, tlsOutcome, string, error) {
	dl := ph.deadlineFor(ctx)
	var o tlsOutcome

	d := net.Dialer{Deadline: dl}
	raw, err := d.DialContext(ctx, "tcp", ph.cfg.proxy)
	if err != nil {
		if isTimeout(err) {
			return 0, o, outcomeTimeout, err
		}
		return 0, o, outcomeConnectError, err
	}
	defer raw.Close()
	cc := &countingConn{Conn: raw, sent: ph.bytesSent, recv: ph.bytesRecv}
	_ = raw.SetDeadline(dl)

	tlsConf := ph.tlsCfg.Clone()
	tlsConf.ServerName = name
	tlsConf.NextProtos = []string{"http/1.1"}
	tc := tls.Client(cc, tlsConf)
	if err := tc.HandshakeContext(ctx); err != nil {
		// A destination-policy rejection by TARGET lands here as a clean EOF:
		// the proxy closed the connection without ever answering the
		// ClientHello. That is tls_error by design, and the raw string is kept.
		return 0, o, classifyTLSErr(err), err
	}
	ph.ctr.handshakes.Add(1)

	hdr := fmt.Sprintf("%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n", ph.cfg.method, ph.cfg.path, name)
	if methodHasBody(ph.cfg.method) || len(ph.cfg.body) > 0 {
		hdr += fmt.Sprintf("Content-Length: %d\r\n", len(ph.cfg.body))
	}
	hdr += "\r\n"
	req := make([]byte, 0, len(hdr)+len(ph.cfg.body))
	req = append(req, hdr...)
	req = append(req, ph.cfg.body...)
	if _, err := tc.Write(req); err != nil {
		return 0, o, classifyAfterHandshake(err), err
	}
	br := bufio.NewReader(tc)
	resp, err := http.ReadResponse(br, &http.Request{Method: ph.cfg.method})
	if err != nil {
		return 0, o, classifyAfterHandshake(err), err
	}
	// Bounded read: the identity endpoint is tiny, and a runaway body must not
	// be able to make a security test allocate without limit.
	body, berr := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	_ = resp.Body.Close()
	if berr != nil {
		return resp.StatusCode, o, classifyAfterHandshake(berr), berr
	}
	o.Body = strings.TrimSpace(string(body))

	// If the endpoint returned the identity JSON, check the name the SERVER
	// observed against the name we asked for. This is the evidence that the
	// proxy tunneled our SNI unchanged rather than substituting another name.
	var id identityBody
	if json.Unmarshal(body, &id) == nil && id.SNI != "" {
		o.SNI = id.SNI
		o.Peer = id.Peer
		ph.ctr.identityCheck.Add(1)
		if !strings.EqualFold(id.SNI, name) {
			ph.ctr.identityBad.Add(1)
			ph.errs.add(fmt.Sprintf("identity_mismatch: requested %s but server observed sni=%s", name, id.SNI))
		}
	}

	if resp.StatusCode >= 400 {
		return resp.StatusCode, o, outcomeHTTPError, nil
	}
	return resp.StatusCode, o, outcomeSuccess, nil
}

func (ph *tlsPhaseIO) worker(ctx context.Context, p *pacer, rng *mathrand.Rand, collect bool, samples *latencySamples) {
	for ctx.Err() == nil {
		if !p.wait(ctx) {
			return
		}
		name := ph.nextName(rng)
		start := time.Now()
		st, o, outcome, err := ph.oneRequest(ctx, name)
		ph.record(outcome, st, name, o, err, time.Since(start), samples, collect)
	}
}

// ---------------------------------------------------------------------------
// DNS wire format (hand-rolled: header + question out, header + rcode + answers in)
// ---------------------------------------------------------------------------

const (
	dnsTypeA     = 1
	dnsTypeNS    = 2
	dnsTypeCNAME = 5
	dnsTypeSOA   = 6
	dnsTypePTR   = 12
	dnsTypeMX    = 15
	dnsTypeTXT   = 16
	dnsTypeAAAA  = 28
	dnsTypeSRV   = 33
	dnsTypeANY   = 255
)

var qtypeByName = map[string]uint16{
	"A": dnsTypeA, "NS": dnsTypeNS, "CNAME": dnsTypeCNAME, "SOA": dnsTypeSOA,
	"PTR": dnsTypePTR, "MX": dnsTypeMX, "TXT": dnsTypeTXT, "AAAA": dnsTypeAAAA,
	"SRV": dnsTypeSRV, "ANY": dnsTypeANY,
}

var rcodeNames = map[int]string{
	0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN",
	4: "NOTIMP", 5: "REFUSED",
}

func rcodeName(rc int) string {
	if n, ok := rcodeNames[rc]; ok {
		return n
	}
	return fmt.Sprintf("RCODE%d", rc)
}

func parseQType(s string) (uint16, error) {
	if t, ok := qtypeByName[strings.ToUpper(strings.TrimSpace(s))]; ok {
		return t, nil
	}
	return 0, fmt.Errorf("unknown -qtype %q (supported: A, AAAA, CNAME, NS, MX, TXT, SOA, PTR, SRV, ANY)", s)
}

func typeName(t uint16) string {
	for name, v := range qtypeByName {
		if v == t {
			return name
		}
	}
	return fmt.Sprintf("TYPE%d", t)
}

func encodeQName(buf []byte, name string) []byte {
	name = strings.TrimSuffix(strings.TrimSpace(name), ".")
	if name == "" {
		return append(buf, 0)
	}
	for _, label := range strings.Split(name, ".") {
		if label == "" {
			continue
		}
		if len(label) > 63 {
			label = label[:63]
		}
		buf = append(buf, byte(len(label)))
		buf = append(buf, label...)
	}
	return append(buf, 0)
}

var dnsIDCounter atomic.Uint32

func dnsID() uint16 {
	var b [2]byte
	if _, err := rand.Read(b[:]); err == nil {
		return binary.BigEndian.Uint16(b[:])
	}
	// crypto/rand does not fail in practice; degrade instead of aborting a run.
	return uint16(dnsIDCounter.Add(1)) ^ uint16(time.Now().UnixNano())
}

// buildDNSQuery emits a single-question, RD=0 query: the POC talks to
// authoritative servers, which must answer from their own zone data.
func buildDNSQuery(id uint16, name string, qtype uint16) []byte {
	b := make([]byte, 0, 64+len(name))
	var hdr [12]byte
	binary.BigEndian.PutUint16(hdr[0:2], id)
	binary.BigEndian.PutUint16(hdr[2:4], 0x0000) // QR=0 opcode=0 AA=0 TC=0 RD=0
	binary.BigEndian.PutUint16(hdr[4:6], 1)      // QDCOUNT
	binary.BigEndian.PutUint16(hdr[6:8], 0)      // ANCOUNT
	binary.BigEndian.PutUint16(hdr[8:10], 0)     // NSCOUNT
	binary.BigEndian.PutUint16(hdr[10:12], 0)    // ARCOUNT
	b = append(b, hdr[:]...)
	b = encodeQName(b, name)
	var tail [4]byte
	binary.BigEndian.PutUint16(tail[0:2], qtype)
	binary.BigEndian.PutUint16(tail[2:4], 1) // QCLASS IN
	return append(b, tail[:]...)
}

type dnsRR struct {
	Name string `json:"name"`
	Type string `json:"type"`
	TTL  uint32 `json:"ttl"`
	Text string `json:"value"`
}

type dnsMessage struct {
	ID      uint16
	Rcode   int
	TC      bool
	AA      bool
	QR      bool
	Answers []dnsRR
}

// decodeName expands a (possibly compressed) domain name at off.
// It returns the name and the offset just past the name in the current record.
func decodeName(msg []byte, off int) (string, int, error) {
	var sb strings.Builder
	pos := off
	next := -1
	jumps := 0
	for {
		if pos >= len(msg) {
			return sb.String(), pos, errors.New("name runs past end of message")
		}
		l := int(msg[pos])
		if l == 0 {
			pos++
			if next < 0 {
				next = pos
			}
			break
		}
		if l&0xc0 == 0xc0 { // compression pointer
			if pos+1 >= len(msg) {
				return sb.String(), pos, errors.New("truncated compression pointer")
			}
			ptr := int(binary.BigEndian.Uint16(msg[pos:pos+2]) & 0x3fff)
			if next < 0 {
				next = pos + 2
			}
			jumps++
			if jumps > 32 || ptr >= len(msg) {
				return sb.String(), next, errors.New("bad compression pointer")
			}
			pos = ptr
			continue
		}
		pos++
		if pos+l > len(msg) {
			return sb.String(), pos, errors.New("label runs past end of message")
		}
		if sb.Len() > 0 {
			sb.WriteByte('.')
		}
		sb.Write(msg[pos : pos+l])
		pos += l
	}
	name := sb.String()
	if name == "" {
		name = "."
	}
	return name, next, nil
}

// parseDNSResponse decodes the header first (so rcode/TC are always known), then
// the answer section best-effort: a truncated or partially malformed answer
// section must not hide the rcode, which is the signal the DNS tests care about.
func parseDNSResponse(msg []byte) (*dnsMessage, error) {
	if len(msg) < 12 {
		return nil, fmt.Errorf("response too short (%d bytes)", len(msg))
	}
	m := &dnsMessage{
		ID:    binary.BigEndian.Uint16(msg[0:2]),
		Rcode: int(binary.BigEndian.Uint16(msg[2:4]) & 0x000f),
		QR:    msg[2]&0x80 != 0,
		AA:    msg[2]&0x04 != 0,
		TC:    msg[2]&0x02 != 0,
	}
	qd := int(binary.BigEndian.Uint16(msg[4:6]))
	an := int(binary.BigEndian.Uint16(msg[6:8]))

	off := 12
	for i := 0; i < qd; i++ {
		_, next, err := decodeName(msg, off)
		if err != nil {
			return m, err
		}
		off = next + 4
	}
	for i := 0; i < an; i++ {
		name, next, err := decodeName(msg, off)
		if err != nil {
			return m, err
		}
		off = next
		if off+10 > len(msg) {
			return m, errors.New("truncated answer record")
		}
		rtype := binary.BigEndian.Uint16(msg[off : off+2])
		ttl := binary.BigEndian.Uint32(msg[off+4 : off+8])
		rdlen := int(binary.BigEndian.Uint16(msg[off+8 : off+10]))
		off += 10
		if off+rdlen > len(msg) {
			return m, errors.New("answer rdata runs past end of message")
		}
		rdata := msg[off : off+rdlen]
		rr := dnsRR{Name: name, Type: typeName(rtype), TTL: ttl}
		switch rtype {
		case dnsTypeA:
			if len(rdata) == 4 {
				rr.Text = net.IP(rdata).String()
			}
		case dnsTypeAAAA:
			if len(rdata) == 16 {
				rr.Text = net.IP(rdata).String()
			}
		case dnsTypeCNAME, dnsTypeNS, dnsTypePTR:
			if s, _, derr := decodeName(msg, off); derr == nil {
				rr.Text = s
			}
		case dnsTypeTXT:
			var parts []string
			for p := 0; p < len(rdata); {
				n := int(rdata[p])
				p++
				if p+n > len(rdata) {
					break
				}
				parts = append(parts, string(rdata[p:p+n]))
				p += n
			}
			rr.Text = strings.Join(parts, " ")
		default:
			rr.Text = fmt.Sprintf("%d bytes", len(rdata))
		}
		m.Answers = append(m.Answers, rr)
		off += rdlen
	}
	return m, nil
}

// ---------------------------------------------------------------------------
// -mode=dns
// ---------------------------------------------------------------------------

type dnsConfig struct {
	server      string
	duration    time.Duration
	qps         float64
	concurrency int
	qtype       uint16
	qtypeName   string
	zone        string
	hostCount   int
	fixedName   string
	proto       string
	timeout     time.Duration
	warmup      time.Duration
	out         string
	label       string
}

type dnsCounters struct {
	sent      atomic.Int64
	received  atomic.Int64
	timeout   atomic.Int64
	netErr    atomic.Int64
	truncated atomic.Int64
}

type rcodeDist struct {
	mu sync.Mutex
	m  map[string]int64
}

func newRcodeDist() *rcodeDist { return &rcodeDist{m: map[string]int64{}} }

func (d *rcodeDist) add(name string) {
	d.mu.Lock()
	d.m[name]++
	d.mu.Unlock()
}

func (d *rcodeDist) snapshot() map[string]int64 {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := make(map[string]int64, len(d.m))
	for k, v := range d.m {
		out[k] = v
	}
	return out
}

type answerSample struct {
	Name    string   `json:"name"`
	Rcode   string   `json:"rcode"`
	Answers []string `json:"answers"`
}

type answerStore struct {
	mu   sync.Mutex
	max  int
	list []answerSample
}

func (a *answerStore) add(s answerSample) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.list) >= a.max {
		return
	}
	a.list = append(a.list, s)
}

func (a *answerStore) samples() []answerSample {
	a.mu.Lock()
	defer a.mu.Unlock()
	out := make([]answerSample, len(a.list))
	copy(out, a.list)
	return out
}

type dnsPhase struct {
	name    string
	dur     time.Duration
	collect bool
}

func runDNS(ctx context.Context, cfg *dnsConfig) error {
	if cfg.server == "" {
		return errors.New("-server is required in dns mode (e.g. 172.28.0.31:5300)")
	}
	if _, _, err := net.SplitHostPort(cfg.server); err != nil {
		return fmt.Errorf("-server %q is not host:port: %w", cfg.server, err)
	}
	if cfg.proto != "udp" && cfg.proto != "tcp" {
		return fmt.Errorf("-proto must be udp or tcp, got %q", cfg.proto)
	}
	if cfg.concurrency < 1 {
		return errors.New("-concurrency must be >= 1")
	}
	if cfg.duration <= 0 {
		return errors.New("-duration must be > 0")
	}
	if cfg.timeout <= 0 {
		return errors.New("-timeout must be > 0")
	}
	if cfg.fixedName == "" && cfg.zone == "" {
		return errors.New("-zone must not be empty unless -fixed-name is given")
	}

	var (
		ctr       = &dnsCounters{}
		rcodes    = newRcodeDist()
		answers   = &answerStore{max: 10}
		errs      = newErrorSamples(10)
		startWall = time.Now().UTC()
	)

	latencyScope := fmt.Sprintf("per query: from just before the %s send to the matching response (or the %s timeout)",
		strings.ToUpper(cfg.proto), cfg.timeout)

	logSnapshot := func() string {
		return fmt.Sprintf("sent=%d received=%d timeout=%d net_err=%d truncated=%d",
			ctr.sent.Load(), ctr.received.Load(), ctr.timeout.Load(), ctr.netErr.Load(), ctr.truncated.Load())
	}

	run := func(pctx context.Context, collect bool) []latencySamples {
		p := newPacer(cfg.qps)
		if p.stop != nil {
			defer p.stop()
		}
		var wg sync.WaitGroup
		results := make([]latencySamples, cfg.concurrency)
		for w := 0; w < cfg.concurrency; w++ {
			wg.Add(1)
			go func(w int) {
				defer wg.Done()
				var samples latencySamples
				rng := mathrand.New(mathrand.NewSource(time.Now().UnixNano() + int64(w)*104729))
				dnsWorker(pctx, cfg, p, rng, ctr, rcodes, answers, errs, collect, &samples)
				results[w] = samples
			}(w)
		}
		wg.Wait()
		return results
	}

	var phases []dnsPhase
	if cfg.warmup > 0 {
		phases = append(phases, dnsPhase{"warmup", cfg.warmup, false})
	}
	phases = append(phases, dnsPhase{"measure", cfg.duration, true})

	var all []latencySamples
	measuredStart, measuredEnd := time.Now(), time.Now()
	for _, ph := range phases {
		phaseCtx, cancel := context.WithTimeout(ctx, ph.dur)
		fmt.Fprintf(os.Stderr, "[client] dns phase %s: %s proto=%s server=%s concurrency=%d target_qps=%.0f\n",
			ph.name, ph.dur, cfg.proto, cfg.server, cfg.concurrency, cfg.qps)
		if ph.collect {
			measuredStart = time.Now()
		}
		pl := progressLogger(phaseCtx, 10*time.Second, logSnapshot)
		parts := run(phaseCtx, ph.collect)
		measuredEnd = time.Now()
		cancel()
		pl.Wait()
		if ph.collect {
			all = parts
		}
	}
	if ctx.Err() != nil {
		measuredEnd = time.Now()
		fmt.Fprintln(os.Stderr, "[client] interrupted; reporting partial results")
	}

	sorted := mergeSamples(all)
	measuredSeconds := measuredEnd.Sub(measuredStart).Seconds()
	if measuredSeconds <= 0 {
		measuredSeconds = cfg.duration.Seconds()
	}

	notes := []string{
		"RD=0: queries are sent without recursion desired, as required for authoritative servers.",
		"For UDP, a response with the TC bit set is counted in 'truncated' and is NOT retried over TCP automatically; its rcode is still counted in 'rcodes'. Truncation is reported as a finding, not papered over.",
		"latency_ms are exact percentiles (nearest-rank) over the merged, sorted per-worker samples; memory scales with sample count (8 bytes/sample, see latency_samples).",
		"achieved_qps = queries_sent / measured_seconds (the actual measurement window).",
		"queries_sent counts queries actually written (or attempted for TCP); timeout and network_error are outcomes, not sent-query failures.",
	}
	if cfg.proto == "tcp" {
		notes = append(notes, "TCP mode uses one connection per query (fresh handshake per query, 2-byte length prefix framing).")
	}
	if cfg.warmup > 0 {
		notes = append(notes, "-warmup traffic runs BEFORE the measurement window, so total wall time is warmup_seconds + duration_seconds; warmup counters and latency samples were discarded.")
	}

	sum := map[string]any{
		"label":              cfg.label,
		"mode":               "dns",
		"server":             cfg.server,
		"proto":              cfg.proto,
		"start_time":         startWall.Format(time.RFC3339),
		"duration_seconds":   cfg.duration.Seconds(),
		"measured_seconds":   round3(measuredSeconds),
		"warmup_seconds":     cfg.warmup.Seconds(),
		"target_qps":         cfg.qps,
		"concurrency":        cfg.concurrency,
		"qtype":              cfg.qtypeName,
		"zone":               cfg.zone,
		"fixed_name":         cfg.fixedName,
		"host_count":         cfg.hostCount,
		"latency_scope":      latencyScope,
		"queries_sent":       ctr.sent.Load(),
		"responses_received": ctr.received.Load(),
		"achieved_qps":       round3(float64(ctr.sent.Load()) / measuredSeconds),
		"timeout":            ctr.timeout.Load(),
		"network_error":      ctr.netErr.Load(),
		"truncated":          ctr.truncated.Load(),
		"rcodes":             rcodes.snapshot(),
		"latency_ms":         summarize(sorted),
		"latency_samples":    len(sorted),
		"answers_sample":     answers.samples(),
		"errors_sample":      errs.list(),
		"notes":              notes,
	}
	return writeSummary(cfg.out, sum)
}

func dnsWorker(ctx context.Context, cfg *dnsConfig, p *pacer, rng *mathrand.Rand, ctr *dnsCounters, rcodes *rcodeDist, answers *answerStore, errs *errorSamples, collect bool, samples *latencySamples) {
	if cfg.proto == "udp" {
		dnsWorkerUDP(ctx, cfg, p, rng, ctr, rcodes, answers, errs, collect, samples)
		return
	}
	dnsWorkerTCP(ctx, cfg, p, rng, ctr, rcodes, answers, errs, collect, samples)
}

func (cfg *dnsConfig) name(rng *mathrand.Rand) string {
	if cfg.fixedName != "" {
		return cfg.fixedName
	}
	return fmt.Sprintf("iot%07d.%s", rng.Intn(cfg.hostCount)+1, cfg.zone)
}

func (cfg *dnsConfig) queryDeadline(ctx context.Context) time.Time {
	dl := time.Now().Add(cfg.timeout)
	if cd, ok := ctx.Deadline(); ok && cd.Before(dl) {
		dl = cd
	}
	return dl
}

// recordDNS is the shared bookkeeping for one query outcome.
func recordDNS(ctr *dnsCounters, rcodes *rcodeDist, answers *answerStore, errs *errorSamples, collect bool, samples *latencySamples,
	name string, msg *dnsMessage, outcome string, err error, lat time.Duration) {
	if collect {
		samples.add(lat)
	}
	switch outcome {
	case "timeout":
		ctr.timeout.Add(1)
		if err != nil {
			errs.add(fmt.Sprintf("timeout: %v", err))
		}
		return
	case "network_error":
		ctr.netErr.Add(1)
		if err != nil {
			errs.add(fmt.Sprintf("network_error: %v", err))
		}
		return
	}
	ctr.received.Add(1)
	if msg == nil {
		return
	}
	rcodes.add(rcodeName(msg.Rcode))
	if msg.TC {
		ctr.truncated.Add(1)
	}
	vals := make([]string, 0, len(msg.Answers))
	for _, a := range msg.Answers {
		vals = append(vals, a.Text)
	}
	answers.add(answerSample{Name: name, Rcode: rcodeName(msg.Rcode), Answers: vals})
}

func dnsWorkerUDP(ctx context.Context, cfg *dnsConfig, p *pacer, rng *mathrand.Rand, ctr *dnsCounters, rcodes *rcodeDist, answers *answerStore, errs *errorSamples, collect bool, samples *latencySamples) {
	var conn *net.UDPConn
	defer func() {
		if conn != nil {
			_ = conn.Close()
		}
	}()
	raddr, err := net.ResolveUDPAddr("udp", cfg.server)
	if err != nil {
		ctr.netErr.Add(1)
		errs.add("resolve server: " + err.Error())
		return
	}
	buf := make([]byte, 4096)
	for ctx.Err() == nil {
		if !p.wait(ctx) {
			return
		}
		if conn == nil {
			c, derr := net.DialUDP("udp", nil, raddr)
			if derr != nil {
				ctr.netErr.Add(1)
				errs.add("dial udp: " + derr.Error())
				continue
			}
			conn = c
		}
		name := cfg.name(rng)
		id := dnsID()
		query := buildDNSQuery(id, name, cfg.qtype)
		start := time.Now()
		_ = conn.SetDeadline(cfg.queryDeadline(ctx))
		ctr.sent.Add(1)
		if _, werr := conn.Write(query); werr != nil {
			recordDNS(ctr, rcodes, answers, errs, collect, samples, name, nil, classifyDNSErr(werr), werr, time.Since(start))
			_ = conn.Close()
			conn = nil
			continue
		}
		// A datagram socket carries at most one outstanding query per worker, so
		// the only reason to loop is a stray/late datagram with another ID.
		for {
			n, rerr := conn.Read(buf)
			if rerr != nil {
				outcome := "network_error"
				if isTimeout(rerr) {
					outcome = "timeout"
				} else {
					_ = conn.Close()
					conn = nil
				}
				recordDNS(ctr, rcodes, answers, errs, collect, samples, name, nil, outcome, rerr, time.Since(start))
				break
			}
			if n < 12 {
				recordDNS(ctr, rcodes, answers, errs, collect, samples, name, nil, "network_error",
					fmt.Errorf("short datagram (%d bytes)", n), time.Since(start))
				break
			}
			if binary.BigEndian.Uint16(buf[0:2]) != id {
				continue // stray datagram: keep waiting inside the same deadline
			}
			msg, perr := parseDNSResponse(buf[:n])
			recordDNS(ctr, rcodes, answers, errs, collect, samples, name, msg, "response", perr, time.Since(start))
			break
		}
	}
}

func dnsWorkerTCP(ctx context.Context, cfg *dnsConfig, p *pacer, rng *mathrand.Rand, ctr *dnsCounters, rcodes *rcodeDist, answers *answerStore, errs *errorSamples, collect bool, samples *latencySamples) {
	buf := make([]byte, 65535)
	for ctx.Err() == nil {
		if !p.wait(ctx) {
			return
		}
		name := cfg.name(rng)
		id := dnsID()
		query := buildDNSQuery(id, name, cfg.qtype)
		start := time.Now()
		dl := cfg.queryDeadline(ctx)

		d := net.Dialer{Deadline: dl}
		conn, derr := d.DialContext(ctx, "tcp", cfg.server)
		if derr != nil {
			ctr.sent.Add(1)
			recordDNS(ctr, rcodes, answers, errs, collect, samples, name, nil, classifyDNSErr(derr), derr, time.Since(start))
			continue
		}
		ctr.sent.Add(1)
		_ = conn.SetDeadline(dl)

		framed := make([]byte, 2+len(query))
		binary.BigEndian.PutUint16(framed[0:2], uint16(len(query)))
		copy(framed[2:], query)
		if _, werr := conn.Write(framed); werr != nil {
			recordDNS(ctr, rcodes, answers, errs, collect, samples, name, nil, classifyDNSErr(werr), werr, time.Since(start))
			_ = conn.Close()
			continue
		}
		var lenb [2]byte
		if _, rerr := io.ReadFull(conn, lenb[:]); rerr != nil {
			recordDNS(ctr, rcodes, answers, errs, collect, samples, name, nil, classifyDNSErr(rerr), rerr, time.Since(start))
			_ = conn.Close()
			continue
		}
		n := int(binary.BigEndian.Uint16(lenb[:]))
		if n > len(buf) {
			recordDNS(ctr, rcodes, answers, errs, collect, samples, name, nil, "network_error",
				fmt.Errorf("response length %d exceeds buffer", n), time.Since(start))
			_ = conn.Close()
			continue
		}
		if _, rerr := io.ReadFull(conn, buf[:n]); rerr != nil {
			recordDNS(ctr, rcodes, answers, errs, collect, samples, name, nil, classifyDNSErr(rerr), rerr, time.Since(start))
			_ = conn.Close()
			continue
		}
		_ = conn.Close()
		msg, perr := parseDNSResponse(buf[:n])
		recordDNS(ctr, rcodes, answers, errs, collect, samples, name, msg, "response", perr, time.Since(start))
	}
}

func classifyDNSErr(err error) string {
	if isTimeout(err) {
		return "timeout"
	}
	return "network_error"
}

// ---------------------------------------------------------------------------
// -mode=dnstest
// ---------------------------------------------------------------------------

func runDNSTest(server, name string, qtype uint16, qtypeStr, proto string, timeout time.Duration) error {
	if server == "" {
		return errors.New("-server is required in dnstest mode")
	}
	if name == "" {
		return errors.New("-name is required in dnstest mode")
	}
	if _, _, err := net.SplitHostPort(server); err != nil {
		return fmt.Errorf("-server %q is not host:port: %w", server, err)
	}
	if proto != "udp" && proto != "tcp" {
		return fmt.Errorf("-proto must be udp or tcp, got %q", proto)
	}
	if timeout <= 0 {
		return errors.New("-timeout must be > 0")
	}

	id := dnsID()
	query := buildDNSQuery(id, name, qtype)

	type result struct {
		Name      string   `json:"name"`
		Type      string   `json:"type"`
		Server    string   `json:"server"`
		Proto     string   `json:"proto"`
		Rcode     string   `json:"rcode"`
		Answers   []string `json:"answers"`
		LatencyMS float64  `json:"latency_ms"`
		Truncated bool     `json:"truncated"`
		AA        bool     `json:"aa"`
		Error     string   `json:"error,omitempty"`
	}
	res := result{Name: strings.TrimSuffix(name, "."), Type: qtypeStr, Server: server, Proto: proto, Answers: []string{}}

	start := time.Now()
	raw, err := dnsExchange(server, proto, query, id, timeout)
	res.LatencyMS = round3(float64(time.Since(start).Nanoseconds()) / 1e6)
	if err != nil {
		res.Error = err.Error()
		res.Rcode = "NETWORK_ERROR"
		if isTimeout(err) {
			res.Rcode = "TIMEOUT"
		}
		_ = writeSummary("", res)
		return fmt.Errorf("dnstest: %v", err) // non-zero exit on timeout/network error
	}
	msg, perr := parseDNSResponse(raw)
	if msg == nil {
		res.Error = perr.Error()
		res.Rcode = "MALFORMED"
		_ = writeSummary("", res)
		return fmt.Errorf("dnstest: %v", perr)
	}
	res.Rcode = rcodeName(msg.Rcode)
	res.Truncated = msg.TC
	res.AA = msg.AA
	for _, a := range msg.Answers {
		res.Answers = append(res.Answers, a.Text)
	}
	if perr != nil {
		res.Error = perr.Error()
	}
	// Exit 0 whenever a response was received, whatever the rcode says.
	return writeSummary("", res)
}

// dnsExchange sends one query and returns the raw response with a matching ID.
func dnsExchange(server, proto string, query []byte, id uint16, timeout time.Duration) ([]byte, error) {
	if proto == "tcp" {
		conn, err := net.DialTimeout("tcp", server, timeout)
		if err != nil {
			return nil, err
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(timeout))
		framed := make([]byte, 2+len(query))
		binary.BigEndian.PutUint16(framed[0:2], uint16(len(query)))
		copy(framed[2:], query)
		if _, err := conn.Write(framed); err != nil {
			return nil, err
		}
		var lenb [2]byte
		if _, err := io.ReadFull(conn, lenb[:]); err != nil {
			return nil, err
		}
		n := int(binary.BigEndian.Uint16(lenb[:]))
		buf := make([]byte, n)
		if _, err := io.ReadFull(conn, buf); err != nil {
			return nil, err
		}
		return buf, nil
	}

	raddr, err := net.ResolveUDPAddr("udp", server)
	if err != nil {
		return nil, err
	}
	conn, err := net.DialUDP("udp", nil, raddr)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	deadline := time.Now().Add(timeout)
	_ = conn.SetDeadline(deadline)
	if _, err := conn.Write(query); err != nil {
		return nil, err
	}
	buf := make([]byte, 4096)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			return nil, err
		}
		if n >= 12 && binary.BigEndian.Uint16(buf[0:2]) == id {
			out := make([]byte, n)
			copy(out, buf[:n])
			return out, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("no response with matching ID %d within %s", id, timeout)
		}
	}
}
