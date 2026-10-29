package com.example.router_panel

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    @Suppress("DEPRECATION")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "router_panel/wifi")
            .setMethodCallHandler { call, result ->
                try {
                    val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                    when (call.method) {
                        "perm" -> {
                            val ask = call.argument<Boolean>("ask") ?: true
                            val ok = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                                PackageManager.PERMISSION_GRANTED
                            if (!ok && ask) {
                                requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION), 77)
                            }
                            result.success(ok)
                        }
                        "info" -> {
                            val i = wm.connectionInfo
                            val m = HashMap<String, Any>()
                            m["rssi"] = i.rssi
                            m["speed"] = i.linkSpeed
                            m["freq"] = i.frequency
                            m["ssid"] = i.ssid ?: ""
                            m["bssid"] = i.bssid ?: ""
                            m["rx"] = if (Build.VERSION.SDK_INT >= 29) i.rxLinkSpeedMbps else -1
                            m["tx"] = if (Build.VERSION.SDK_INT >= 29) i.txLinkSpeedMbps else -1
                            m["std"] = if (Build.VERSION.SDK_INT >= 30) i.wifiStandard else 0
                            result.success(m)
                        }
                        "startScan" -> result.success(wm.startScan())
                        "results" -> {
                            val out = ArrayList<HashMap<String, Any>>()
                            for (r in wm.scanResults) {
                                val m = HashMap<String, Any>()
                                m["ssid"] = r.SSID ?: ""
                                m["bssid"] = r.BSSID ?: ""
                                m["level"] = r.level
                                m["freq"] = r.frequency
                                m["width"] = if (Build.VERSION.SDK_INT >= 23) r.channelWidth else 0
                                out.add(m)
                            }
                            result.success(out)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("wifi", e.toString(), null)
                }
            }
    }
}
