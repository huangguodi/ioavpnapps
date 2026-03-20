package com.accelerator.tg

import android.util.Log
import android.os.Debug
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.content.pm.ApplicationInfo
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.accelerator.tg/mihomo"
    private val SECURITY_CHANNEL = "com.accelerator.tg/security"
    private val VPN_REQUEST_CODE = 24
    private var pendingConfigPath: String? = null
    private var pendingResult: MethodChannel.Result? = null

    private var eventSink: io.flutter.plugin.common.EventChannel.EventSink? = null

    // Load the native library
    init {
        System.loadLibrary("crypto_keys")
    }

    // Native methods
    external fun getAesKey(): String
    external fun getObfuscateKey(): String
    external fun getServerUrlKey(): String

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MihomoVpnService.logCallback = { message ->
            runOnUiThread { eventSink?.success(message) }
        }

        io.flutter.plugin.common.EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.accelerator.tg/mihomo/logs")
            .setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: io.flutter.plugin.common.EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        io.flutter.plugin.common.EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.accelerator.tg/mihomo/traffic")
            .setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
                private var handler: android.os.Handler? = null
                private var runnable: Runnable? = null
                override fun onListen(arguments: Any?, events: io.flutter.plugin.common.EventChannel.EventSink?) {
                    handler = android.os.Handler(android.os.Looper.getMainLooper())
                    runnable = object : Runnable {
                        override fun run() {
                            try {
                                if (MihomoManager.isRunning()) {
                                    val (up, down) = MihomoManager.getTraffic()
                                    events?.success(mapOf("up" to up, "down" to down))
                                }
                            } catch (e: Exception) {
                                // ignore
                            }
                            handler?.postDelayed(this, 1000)
                        }
                    }
                    handler?.post(runnable!!)
                }

                override fun onCancel(arguments: Any?) {
                    runnable?.let { handler?.removeCallbacks(it) }
                    handler = null
                    runnable = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURITY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enableSecureMode" -> {
                    runOnUiThread {
                        window.setFlags(
                            WindowManager.LayoutParams.FLAG_SECURE,
                            WindowManager.LayoutParams.FLAG_SECURE
                        )
                    }
                    result.success(true)
                }
                "isDebuggerAttached" -> {
                    result.success(Debug.isDebuggerConnected() || Debug.waitingForDebugger())
                }
                "isAppDebuggable" -> {
                    val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
                    result.success(debuggable)
                }
                "isProxyDetected" -> {
                    val host = System.getProperty("http.proxyHost")
                    val httpsHost = System.getProperty("https.proxyHost")
                    val hasProxyHost = !host.isNullOrBlank() || !httpsHost.isNullOrBlank()
                    result.success(hasProxyHost)
                }
                "getAesKey" -> {
                    try {
                        result.success(getAesKey())
                    } catch (e: Exception) {
                        result.error("GET_AES_KEY_FAILED", e.message, null)
                    }
                }
                "getObfuscateKey" -> {
                    try {
                        result.success(getObfuscateKey())
                    } catch (e: Exception) {
                        result.error("GET_OBFUSCATE_KEY_FAILED", e.message, null)
                    }
                }
                "getServerUrlKey" -> {
                    try {
                        result.success(getServerUrlKey())
                    } catch (e: Exception) {
                        result.error("GET_SERVER_URL_KEY_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "initAssets") {
                try {
                    copyAssetToFiles("mihomo_android/mihomo", "mihomo")
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INIT_FAILED", "Failed to copy assets: ${e.message}", null)
                }
            } else if (call.method == "getAesKey") {
                try {
                    result.success(getAesKey())
                } catch (e: Exception) {
                    result.error("GET_AES_KEY_FAILED", e.message, null)
                }
            } else if (call.method == "getObfuscateKey") {
                try {
                    result.success(getObfuscateKey())
                } catch (e: Exception) {
                    result.error("GET_OBFUSCATE_KEY_FAILED", e.message, null)
                }
            } else if (call.method == "getServerUrlKey") {
                try {
                    result.success(getServerUrlKey())
                } catch (e: Exception) {
                    result.error("GET_SERVER_URL_KEY_FAILED", e.message, null)
                }
            } else if (call.method == "startMihomo") {
                val configPath = call.argument<String>("configPath")
                val vpnIntent = VpnService.prepare(this)
                if (vpnIntent != null) {
                    pendingConfigPath = configPath
                    pendingResult = result
                    startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                } else {
                    startVpnService(configPath)
                    result.success(null)
                }
            } else if (call.method == "start") {
                val configPath = call.argument<String>("configPath")
                val vpnIntent = VpnService.prepare(this)
                if (vpnIntent != null) {
                    pendingConfigPath = configPath
                    pendingResult = result
                    startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
                } else {
                    startVpnService(configPath)
                    result.success(null)
                }
            } else if (call.method == "stopMihomo") {
                val intent = Intent(this, MihomoVpnService::class.java)
                stopService(intent)
                result.success(null)
            } else if (call.method == "stop") {
                val intent = Intent(this, MihomoVpnService::class.java)
                stopService(intent)
                result.success(null)
            } else if (call.method == "queryTunnelState") {
                try {
                    if (!MihomoManager.isRunning()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val mode = MihomoManager.getModeFallback()
                    val json = """{"mode":"$mode"}"""
                    result.success(json)
                } catch (e: Exception) {
                    result.error("QUERY_FAILED", e.message, null)
                }
            } else if (call.method == "isMihomoRunning") {
                result.success(MihomoManager.isRunning())
            } else if (call.method == "isRunning") {
                result.success(MihomoManager.isRunning())
            } else if (call.method == "queryTrafficNow") {
                try {
                    val (up, down) = MihomoManager.getTraffic()
                    val source = MihomoManager.getTrafficSource()
                    result.success(mapOf("up" to up, "down" to down, "source" to source))
                } catch (e: Exception) {
                    result.error("QUERY_FAILED", e.message, null)
                }
            } else if (call.method == "queryGroupNames") {
                result.success("[]")
            } else if (call.method == "queryGroup") {
                result.success("{}")
            } else if (call.method == "patchSelector") {
                result.success(false)
            } else if (call.method == "urlTest") {
                val name = call.argument<String>("name")
                if (name.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "name cannot be empty", null)
                } else {
                    Thread {
                        try {
                            val latency = MihomoManager.testLatency(name)
                            runOnUiThread {
                                result.success(latency)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("TEST_LATENCY_FAILED", e.message, null)
                            }
                        }
                    }.start()
                }
            } else if (call.method == "reloadConfig") {
                val ok = MihomoVpnService.instance?.reloadConfig() ?: false
                result.success(ok)
            } else if (call.method == "setModeNative") {
                try {
                    val mode = (call.argument<String>("mode") ?: "rule").lowercase()
                    if (mode != "rule" && mode != "global" && mode != "direct") {
                        result.error("INVALID_MODE", "Invalid mode: $mode", null)
                        return@setMethodCallHandler
                    }
                    val success = MihomoManager.setMode(mode)
                    if (success) {
                        result.success(true)
                    } else {
                        result.error("SET_MODE_FAILED", "Failed to set mode: $mode", null)
                    }
                } catch (e: Exception) {
                    result.error("SET_MODE_FAILED", e.message, null)
                }
            } else if (call.method == "getModeNative") {
                try {
                    result.success(MihomoManager.getMode())
                } catch (e: Exception) {
                    result.error("GET_MODE_FAILED", e.message, null)
                }
            } else if (call.method == "getMode") {
                try {
                    result.success(MihomoManager.getMode())
                } catch (e: Exception) {
                    result.error("GET_MODE_FAILED", e.message, null)
                }
            } else if (call.method == "getProxies") {
                try {
                    val proxies = MihomoManager.getProxies()
                    result.success(proxies)
                } catch (e: Exception) {
                    result.error("GET_PROXIES_FAILED", e.message, null)
                }
            } else if (call.method == "changeMode") {
                try {
                    val mode = (call.argument<String>("mode") ?: "rule").lowercase()
                    if (mode != "rule" && mode != "global" && mode != "direct") {
                        result.error("INVALID_MODE", "Invalid mode: $mode", null)
                        return@setMethodCallHandler
                    }
                    val success = MihomoManager.setMode(mode)
                    if (success) {
                        result.success(true)
                    } else {
                        result.error("SET_MODE_FAILED", "Failed to set mode: $mode", null)
                    }
                } catch (e: Exception) {
                    result.error("SET_MODE_FAILED", e.message, null)
                }
            } else if (call.method == "selectProxy") {
                try {
                    val proxyName = if (call.arguments is String) {
                        call.arguments as String
                    } else {
                        call.argument<String>("name") ?: call.argument<String>("proxyName")
                    }
                    
                    if (proxyName.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "proxyName cannot be empty (arg: ${call.arguments})", null)
                        return@setMethodCallHandler
                    }
                    val success = MihomoManager.selectProxy(proxyName)
                    result.success(success)
                } catch (e: Exception) {
                    result.error("SELECT_PROXY_FAILED", e.message, null)
                }
            } else if (call.method == "selectProxyByGroup") {
                try {
                    val groupName = call.argument<String>("groupName")
                    val proxyName = call.argument<String>("name") ?: call.argument<String>("proxyName")
                    if (groupName.isNullOrBlank() || proxyName.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "groupName/proxyName cannot be empty", null)
                        return@setMethodCallHandler
                    }
                    val success = MihomoManager.selectProxy(groupName, proxyName)
                    result.success(success)
                } catch (e: Exception) {
                    result.error("SELECT_PROXY_FAILED", e.message, null)
                }
            } else if (call.method == "getSelectedProxy") {
                val groupName = call.argument<String>("groupName")
                if (groupName.isNullOrBlank()) {
                     result.error("INVALID_ARGUMENT", "groupName cannot be empty", null)
                } else {
                     result.success(MihomoManager.getSelectedProxy(groupName))
                }
            } else if (call.method == "patchOverride") {
                val mode = call.argument<String>("mode")
                if (mode.isNullOrBlank()) {
                    result.error("INVALID_MODE", "Invalid mode: $mode", null)
                } else {
                    result.success(MihomoManager.setMode(mode))
                }
            } else if (call.method == "queryProviders") {
                result.success("{}")
            } else if (call.method == "updateNotification") {
                val content = call.argument<String>("content")
                if (content != null) {
                    MihomoVpnService.instance?.updateNotification(content)
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENT", "Content cannot be null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                startVpnService(pendingConfigPath)
                pendingResult?.success(null)
            } else {
                pendingResult?.error("VPN_PERMISSION_DENIED", "User denied VPN permission", null)
            }
            pendingResult = null
            pendingConfigPath = null
        } else {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private fun startVpnService(configPath: String?) {
        // Fix Path Traversal Risk
        if (configPath != null) {
            val file = File(configPath)
            if (!file.canonicalPath.startsWith(filesDir.canonicalPath)) {
                // Potential path traversal attack
                return
            }
        }

        val intent = Intent(this, MihomoVpnService::class.java).apply {
            putExtra("configPath", configPath)
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (e: Exception) {
            // Log removed to prevent leakage
        }
    }

    // copyAssetToFiles is no longer needed for mihomo, but kept if other assets need it
    private fun copyAssetToFiles(assetName: String, fileName: String) {
        // Fix Path Traversal Risk
        if (fileName.contains("..") || fileName.contains("/") || fileName.contains("\\")) {
            return
        }
        
        val file = File(filesDir, fileName)
        if (!file.canonicalPath.startsWith(filesDir.canonicalPath)) {
             return
        }

        if (!file.exists()) {
             assets.open(assetName).use { input ->
                 file.outputStream().use { output ->
                     input.copyTo(output)
                 }
             }
             // Fix Permission Risk: Only set executable for specific binaries if absolutely needed
             if (fileName == "mihomo" || fileName.endsWith(".so")) {
                 file.setExecutable(true)
             }
        } else {
             // Ensure executable even if exists
             if (fileName == "mihomo" || fileName.endsWith(".so")) {
                 file.setExecutable(true)
             }
        }
    }
}
