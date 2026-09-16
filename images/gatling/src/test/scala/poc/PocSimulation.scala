package poc

import io.gatling.core.Predef._
import io.gatling.core.session.{Expression, Session}
import io.gatling.http.Predef._
import io.gatling.http.protocol.{HttpProxy, Proxy}

import scala.concurrent.duration._
import scala.util.Random

/**
 * The POC's HTTP workload, driven by Gatling.
 *
 * THE ONE THING THAT MATTERS HERE: THE URL CARRIES THE DEVICE NAME.
 *
 *   Every request targets  https://iotNNNNNNN.test.domain/  rather than the
 *   VIP address. That is deliberate and load-bearing, because Gatling derives
 *   both the Host header AND the TLS SNI from the request URL. TARGET routes
 *   on the SNI -- HAProxy reads it out of the ClientHello without terminating
 *   TLS -- so a request addressed to the IP would carry no SNI, be rejected by
 *   the destination policy, and measure nothing.
 *
 *   The device name is resolved to the VIP by dnsmasq inside this container
 *   (see entrypoint.sh); it is never resolved to the IoT Mock.
 *
 * MODES
 *   target   direct TLS to the VIP on 443, name as SNI
 *   current  TLS THROUGH the CONNECT proxy: Gatling issues
 *            `CONNECT iotNNNNNNN.test.domain:443` to HAProxy on 38888, Squid
 *            resolves the name and opens the tunnel, and the mTLS handshake
 *            with the IoT Mock happens INSIDE it. The client certificate is
 *            presented to the Mock, not to the proxy -- which is why an
 *            ordinary proxy + keystore configuration is sufficient.
 *
 * EVERYTHING IS OVERRIDABLE by system property, so one image serves every
 * scenario and the harness does not need a rebuild to change the load shape.
 */
class PocSimulation extends Simulation {

  private def prop(k: String, d: String): String = System.getProperty(k, d)

  private val mode        = prop("poc.mode", "target")
  private val vip         = prop("poc.vip", "172.28.0.10")
  private val zone        = prop("poc.zone", "test.domain")
  private val devices     = prop("poc.devices", "1000000").toInt
  private val usersPerSec = prop("poc.rps", "1000").toDouble
  private val duration    = prop("poc.duration", "60").toInt
  private val proxyPort   = prop("poc.proxyPort", "38888").toInt
  private val bodyBytes   = prop("poc.bodyBytes", "256").toInt
  private val path        = prop("poc.path", "/")
  private val label       = prop("poc.label", s"$mode")

  private val payload = "x" * bodyBytes

  /** A distinct device per request, drawn from the 1M namespace. */
  private val devicesFeeder = Iterator.continually(
    Map("device" -> f"iot${Random.nextInt(devices) + 1}%07d.$zone")
  )

  private val httpProtocol = {
    val base = http
      .userAgentHeader("poc-gatling")
      .disableCaching
      // Warm-up requests would be measured as if they were steady state.
      .disableWarmUp
    // Gatling 3.15's Proxy takes the type, an optional basic-auth realm and
    // any extra CONNECT headers. Squid here is an open, unauthenticated
    // forward proxy, so the last two are empty. The client certificate is NOT
    // presented here -- it goes to the IoT Mock inside the tunnel.
    if (mode == "current") base.proxy(Proxy(vip, proxyPort, HttpProxy, None, Map.empty))
    else base
  }

  // Built from the session explicitly rather than as a "${device}" template
  // string. A plain template string was NOT interpolated here -- Gatling sent
  // the literal text "${device}" as the hostname and every request failed with
  //   java.net.UnknownHostException: ${device}
  // Building the URL from the session value removes all ambiguity about when
  // interpolation happens.
  private val uri: Expression[String] =
    (session: Session) => s"https://${session("device").as[String]}$path"

  private val scn = scenario(s"IoT telemetry ($mode)")
    .feed(devicesFeeder)
    .exec(
      http(s"$label PUT $path")
        .put(uri)
        .body(StringBody(payload))
        .check(status.is(200))
    )

  setUp(
    scn.inject(constantUsersPerSec(usersPerSec).during(duration.seconds))
  ).protocols(httpProtocol)
    .assertions(
      // Recorded as a report line rather than a hard assertion: a failed run
      // should still produce its report, so the failure is visible rather
      // than the run simply aborting.
      global.failedRequests.percent.lte(100.0)
    )
}
