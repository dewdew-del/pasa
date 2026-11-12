package com.dewdewdel.pasa

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Joins the laptop's own Wi-Fi network. Android shows one "Connect" prompt; the app's traffic is
 * then routed through that network while the rest of the phone keeps using mobile data.
 */
class MainActivity : FlutterActivity() {
    private var callback: ConnectivityManager.NetworkCallback? = null

    private val cm get() = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pasa/wifi").setMethodCallHandler { call, result ->
            when (call.method) {
                "join" -> join(call.argument<String>("ssid")!!, call.argument<String>("pass")!!, result)
                "leave" -> { leave(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun join(ssid: String, pass: String, result: MethodChannel.Result) {
        leave()
        val main = Handler(Looper.getMainLooper())
        var answered = false
        fun answer(ok: Boolean) {
            main.post { if (!answered) { answered = true; result.success(ok) } }
        }

        val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).setWpa2Passphrase(pass).build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) // laptop network has no internet
            .setNetworkSpecifier(spec)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cm.bindProcessToNetwork(network) // Pasa's sockets go to the laptop network
                answer(true)
            }
            override fun onUnavailable() {
                answer(false) // user tapped Cancel or network not found
            }
            override fun onLost(network: Network) {
                cm.bindProcessToNetwork(null)
            }
        }
        callback = cb
        cm.requestNetwork(request, cb, 60_000) // the prompt waits for the user; give up after a minute
    }

    private fun leave() {
        callback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        callback = null
        cm.bindProcessToNetwork(null)
    }

    override fun onDestroy() {
        leave()
        super.onDestroy()
    }
}
