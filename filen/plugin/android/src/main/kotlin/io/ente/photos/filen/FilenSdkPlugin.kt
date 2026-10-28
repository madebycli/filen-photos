package io.ente.photos.filen

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * MethodChannel facade for [FilenBackend]. Every call runs on an IO coroutine and answers on the
 * main thread. The backend is process-wide so that background isolates (workmanager) share the
 * session with the UI isolate.
 */
class FilenSdkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val value = dispatch(call)
                withContext(Dispatchers.Main) { result.success(value) }
            } catch (e: FilenException) {
                withContext(Dispatchers.Main) { result.error(e.code, e.message, null) }
            } catch (e: NotImplementedError) {
                withContext(Dispatchers.Main) { result.notImplemented() }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) { result.error("PLUGIN_ERROR", e.message, null) }
            }
        }
    }

    private suspend fun dispatch(call: MethodCall): Any? {
        fun str(key: String): String = call.argument<String>(key) ?: throw FilenException("BAD_ARGS", "missing $key")
        return when (call.method) {
            "login" -> backend.login(str("email"), str("password"), call.argument<String>("twoFactorCode"))
            "restore" -> { backend.restore(str("session")); null }
            "logout" -> { backend.logout(); null }
            "isLoggedIn" -> backend.isLoggedIn
            "userInfo" -> backend.userInfo()
            "rootUuid" -> backend.rootUuid()
            "listTree" -> backend.listTree(str("rootUuid"))
            "findOrCreateRootChild" -> backend.findOrCreateRootChild(str("name"))
            "createDir" -> backend.createDir(str("parentUuid"), str("name"))
            "downloadFile" -> { backend.downloadFile(str("uuid"), str("destPath")); null }
            "thumbnail" -> backend.thumbnail(
                str("uuid"),
                call.argument<Int>("maxWidth") ?: 512,
                call.argument<Int>("maxHeight") ?: 512,
            )
            "uploadFile" -> backend.uploadFile(
                str("localPath"),
                str("parentUuid"),
                call.argument<String>("name"),
                (call.argument<Number>("createdMs"))?.toLong(),
                (call.argument<Number>("modifiedMs"))?.toLong(),
                call.argument<String>("mime"),
            )
            else -> throw NotImplementedError()
        }
    }

    companion object {
        const val CHANNEL = "io.ente.photos/filen_sdk"
        private val backend = FilenBackend()
    }
}
