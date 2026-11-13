package com.dewdewdel.pasa

import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.wifi.WifiManager
import android.webkit.MimeTypeMap
import android.provider.Settings
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
                "wifiOn" -> result.success((applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).isWifiEnabled)
                "openWifiPanel" -> {
                    // Apps can't switch Wi-Fi on by themselves since Android 10; this sheet is one tap.
                    startActivity(Intent(Settings.Panel.ACTION_WIFI))
                    result.success(null)
                }
                "openFile" -> openFile(call.argument<String>("path")!!, result)
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

    // The media scanner hands back a content:// link other apps may read, so no FileProvider is needed.
    private fun openFile(path: String, result: MethodChannel.Result) {
        val main = Handler(Looper.getMainLooper())
        val type = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(path.substringAfterLast('.', "").lowercase()) ?: "*/*"
        MediaScannerConnection.scanFile(this, arrayOf(path), arrayOf(type)) { _, uri ->
            main.post {
                try {
                    startActivity(
                        Intent(Intent.ACTION_VIEW).setDataAndType(uri!!, type)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    )
                    result.success(null)
                } catch (e: Exception) {
                    result.error("open", e.message, null) // no app for this type, or scan failed
                }
            }
        }
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
