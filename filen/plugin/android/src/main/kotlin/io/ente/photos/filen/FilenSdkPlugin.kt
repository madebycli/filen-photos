package io.ente.photos.filen

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
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
    private var appContext: Context? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
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
                Log.w(TAG, "${call.method} -> ${e.code}: ${e.message}")
                withContext(Dispatchers.Main) { result.error(e.code, e.message, null) }
            } catch (e: NotImplementedError) {
                withContext(Dispatchers.Main) { result.notImplemented() }
            } catch (e: Exception) {
                Log.e(TAG, "${call.method} crashed", e)
                withContext(Dispatchers.Main) {
                    result.error("PLUGIN_ERROR", "${e.javaClass.simpleName}: ${e.message}", e.stackTraceToString().take(2000))
                }
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
            // The wallpaper-based accent of Android 12+ ("Material You"); null on older Android.
            "systemAccent" -> if (Build.VERSION.SDK_INT >= 31) {
                appContext?.getColor(android.R.color.system_accent1_500)
            } else {
                null
            }
            "userInfo" -> backend.userInfo()
            "rootUuid" -> backend.rootUuid()
            "dirSize" -> backend.dirSize(str("uuid"))
            "listTree" -> backend.listTree(
                str("rootUuid"),
                (call.argument<List<String>>("skipDirNames") ?: emptyList()).toSet(),
            )
            "trashDir" -> { backend.trashDir(str("uuid")); null }
            "renameDir" -> { backend.renameDir(str("uuid"), str("name")); null }
            "findOrCreateRootChild" -> backend.findOrCreateRootChild(str("name"))
            "createDir" -> backend.createDir(str("parentUuid"), str("name"))
            "listFolder" -> backend.listFolder(str("uuid"))
            "ensureDir" -> backend.ensureDir(str("parentUuid"), str("name"))
            "readBytes" -> backend.readBytes(str("uuid"))
            "writeBytes" -> backend.writeBytes(
                str("parentUuid"),
                str("name"),
                call.argument<ByteArray>("data") ?: throw FilenException("BAD_ARGS", "missing data"),
                (call.argument<Number>("modifiedMs"))?.toLong(),
            )
            "deleteFilePermanently" -> { backend.deleteFilePermanently(str("uuid")); null }
            "streamUrl" -> backend.streamUrl(str("uuid"))
            "trashFile" -> { backend.trashFile(str("uuid")); null }
            "listTrash" -> backend.listTrash()
            "restoreFile" -> { backend.restoreFile(str("uuid")); null }
            "emptyTrash" -> { backend.emptyTrash(); null }
            "moveFile" -> { backend.moveFile(str("uuid"), str("newParentUuid")); null }
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
                call.argument<String>("id")?.let { id ->
                    { delta: Long ->
                        // Back to the main thread, where the channel must be used.
                        Handler(Looper.getMainLooper()).post {
                            channel?.invokeMethod("uploadProgress", mapOf("id" to id, "bytes" to delta))
                        }
                    }
                },
            )
            else -> throw NotImplementedError()
        }
    }

    companion object {
        const val CHANNEL = "io.ente.photos/filen_sdk"
        private const val TAG = "FilenSdk"
        private val backend = FilenBackend()
    }
}
