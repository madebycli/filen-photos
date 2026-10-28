package io.ente.photos.filen

import android.util.Log
import org.json.JSONObject
import uniffi.filen_sdk_rs.LogLevel
import uniffi.filen_sdk_rs.init as uniffiInit
import uniffi.filen_sdk_rs.setLogLevel as uniffiSetLogLevel
import uniffi.filen_sdk_rs.AnyFile
import uniffi.filen_sdk_rs.AnyNormalDir
import uniffi.filen_sdk_rs.DirMeta
import uniffi.filen_sdk_rs.ErrorKind
import uniffi.filen_sdk_rs.File
import uniffi.filen_sdk_rs.CreatedTime
import uniffi.filen_sdk_rs.DirectoryMetaChanges
import uniffi.filen_sdk_rs.FileBuilderParams
import uniffi.filen_sdk_rs.FileBuilderParamsOptionalName
import uniffi.filen_sdk_rs.FileMetaChanges
import uniffi.filen_sdk_rs.HttpProviderHandle
import uniffi.filen_sdk_rs.UploadFileParams
import uniffi.filen_sdk_rs.FileMeta
import uniffi.filen_sdk_rs.FilenSdkException
import uniffi.filen_sdk_rs.JsClient
import uniffi.filen_sdk_rs.JsClientConfig
import uniffi.filen_sdk_rs.LoginParams
import uniffi.filen_sdk_rs.MakeThumbnailInMemoryParams
import uniffi.filen_sdk_rs.MakeThumbnailInMemoryResult
import uniffi.filen_sdk_rs.ManagedFuture
import uniffi.filen_sdk_rs.Root
import uniffi.filen_sdk_rs.StringifiedClient
import uniffi.filen_sdk_rs.UnauthJsClient

/** Error that the Dart side can switch on; [code] is stable, [message] is for logs only. */
private const val TAG = "FilenSdk"

class FilenException(val code: String, message: String?) : Exception(message)

/**
 * Thin adapter around Filen's official SDK bindings. It holds the authenticated client and
 * translates the SDK's types into plain maps. No networking or cryptography happens here:
 * everything is delegated to `filen-sdk-rs`.
 */
class FilenBackend {
    @Volatile
    private var client: JsClient? = null

    init {
        // The SDK ships its own logcat sink (tag per Rust target); DEBUG shows requests and retries.
        try {
            uniffiInit()
            uniffiSetLogLevel(LogLevel.DEBUG)
            Log.i(TAG, "Filen SDK logging to logcat at DEBUG")
        } catch (e: Throwable) {
            Log.w(TAG, "Could not enable Filen SDK logging", e)
        }
    }

    private fun requireClient(): JsClient =
        client ?: throw FilenException("NOT_LOGGED_IN", "No Filen session")

    val isLoggedIn: Boolean get() = client != null

    private fun unauth(): UnauthJsClient = UnauthJsClient.fromConfig(
        JsClientConfig(
            concurrency = null,
            rateLimitPerSec = null,
            uploadBandwidthKilobytesPerSec = null,
            downloadBandwidthKilobytesPerSec = null,
            logLevel = null,
            fileIoMemoryBudget = null,
        ),
    )

    /** Returns the serialized session; the caller keeps it in the Android Keystore backed storage. */
    suspend fun login(email: String, password: String, twoFactorCode: String?): String =
        wrap {
            Log.i(TAG, "login: starting (2fa code ${if (twoFactorCode.isNullOrBlank()) "absent" else "given"})")
            val c = unauth().login(LoginParams(email, password, twoFactorCode?.ifBlank { null }))
            client = c
            Log.i(TAG, "login: ok")
            serialize(c.toStringified())
        }

    suspend fun restore(session: String) = wrap {
        client = unauth().fromStringified(deserialize(session))
        Log.i(TAG, "session restored")
    }

    fun logout() {
        httpProvider?.destroy()
        httpProvider = null
        client?.destroy()
        client = null
    }

    suspend fun userInfo(): Map<String, Any?> = wrap {
        val info = requireClient().getUserInfo()
        mapOf(
            "email" to info.email,
            "userId" to info.id.toLong(),
            "storageUsed" to info.storageUsed.toLong(),
            "maxStorage" to info.maxStorage.toLong(),
            "rootUuid" to info.rootDirUuid,
            "nickName" to info.nickName,
        )
    }

    suspend fun rootUuid(): String = wrap { requireClient().root().uuid }

    /**
     * Lists every folder and file below [rootUuid] (breadth first), so Dart can mirror a whole
     * photo tree with one call. Parents are reported by uuid.
     */
    suspend fun listTree(rootUuid: String, skipDirNames: Set<String> = emptySet()): Map<String, Any?> = wrap {
        val c = requireClient()
        val dirs = ArrayList<Map<String, Any?>>()
        val files = ArrayList<Map<String, Any?>>()
        val queue = ArrayDeque<String>()
        queue.add(rootUuid)
        while (queue.isNotEmpty()) {
            val uuid = queue.removeFirst()
            val listing = c.listDir(dirTarget(c, uuid))
            for (d in listing.dirs) {
                if (dirName(d.meta) in skipDirNames) continue
                dirs.add(
                    mapOf(
                        "uuid" to d.uuid,
                        "parent" to uuid,
                        "name" to dirName(d.meta),
                    ),
                )
                queue.add(d.uuid)
            }
            for (f in listing.files) {
                fileMap(f, uuid)?.let { files.add(it) }
            }
        }
        mapOf("dirs" to dirs, "files" to files)
    }

    private suspend fun dirTarget(c: JsClient, uuid: String): AnyNormalDir =
        if (uuid == c.root().uuid) AnyNormalDir.Root(Root(uuid)) else AnyNormalDir.Dir(c.getDir(uuid))

    /** Finds (or creates) a direct child folder of the drive root and returns its uuid. */
    suspend fun findOrCreateRootChild(name: String): String = wrap {
        val c = requireClient()
        val root = c.root()
        val existing = c.listDir(AnyNormalDir.Root(root)).dirs.firstOrNull { dirName(it.meta) == name }
        existing?.uuid ?: c.createDir(AnyNormalDir.Root(root), name).uuid
    }

    suspend fun createDir(parentUuid: String, name: String): String = wrap {
        val c = requireClient()
        c.createDir(dirTarget(c, parentUuid), name).uuid
    }

    suspend fun downloadFile(uuid: String, destPath: String) = wrap {
        val c = requireClient()
        val file = c.getFile(uuid)
        c.downloadFileToPath(AnyFile.File(file), destPath, null, ManagedFuture(null, null))
    }

    /** One level of a folder, nothing recursive: used for the app's own state folder. */
    suspend fun listFolder(uuid: String): Map<String, Any?> = wrap {
        val c = requireClient()
        val listing = c.listDir(dirTarget(c, uuid))
        mapOf(
            "dirs" to listing.dirs.map { d ->
                mapOf("uuid" to d.uuid, "parent" to uuid, "name" to dirName(d.meta))
            },
            "files" to listing.files.mapNotNull { fileMap(it, uuid) },
        )
    }

    /** Returns the uuid of the child folder [name] of [parentUuid], creating it when missing. */
    suspend fun ensureDir(parentUuid: String, name: String): String = wrap {
        val c = requireClient()
        val existing = c.listDir(dirTarget(c, parentUuid)).dirs.firstOrNull { dirName(it.meta) == name }
        existing?.uuid ?: c.createDir(dirTarget(c, parentUuid), name).uuid
    }

    suspend fun readBytes(uuid: String): ByteArray = wrap {
        val c = requireClient()
        c.downloadFileToBytes(AnyFile.File(c.getFile(uuid)), ManagedFuture(null, null))
    }

    /** Creates a new file; the caller picks unique names (Filen would otherwise replace by name). */
    suspend fun writeBytes(parentUuid: String, name: String, data: ByteArray, modifiedMs: Long?): Map<String, Any?> = wrap {
        val c = requireClient()
        val file = c.uploadFileFromBytes(
            data,
            UploadFileParams(
                FileBuilderParams(
                    parent = dirTarget(c, parentUuid),
                    name = name,
                    created = null,
                    modified = modifiedMs,
                    mime = null,
                    noExif = true,
                ),
                ManagedFuture(null, null),
            ),
        )
        fileMap(file, parentUuid) ?: throw FilenException("INTERNAL", "written file has no readable metadata")
    }

    /** Permanent delete. Only ever used on the app's own state files, never on user photos. */
    suspend fun deleteFilePermanently(uuid: String) = wrap {
        val c = requireClient()
        c.deleteFilePermanently(c.getFile(uuid))
    }

    /** Sets the capture/modification time stored by Filen. */
    suspend fun setFileTimes(uuid: String, createdMs: Long?, modifiedMs: Long?) = wrap {
        val c = requireClient()
        c.updateFileMetadata(
            c.getFile(uuid),
            FileMetaChanges(
                name = null,
                mime = null,
                lastModified = modifiedMs,
                created = if (createdMs == null) CreatedTime.Keep else CreatedTime.Set(createdMs),
            ),
        )
        Unit
    }

    @Volatile
    private var httpProvider: HttpProviderHandle? = null

    /**
     * A 127.0.0.1 URL that streams the decrypted file with range support, for the video player.
     * The SDK's own HTTP provider does the decrypting; nothing is stored on disk.
     */
    suspend fun streamUrl(uuid: String): String = wrap {
        val c = requireClient()
        val provider = httpProvider ?: c.startHttpProvider(null).also { httpProvider = it }
        provider.getFileUrl(AnyFile.File(c.getFile(uuid)))
    }

    /** Moves a folder (with everything in it) to Filen's trash, where it stays recoverable. */
    suspend fun trashDir(uuid: String) = wrap {
        val c = requireClient()
        c.trashDir(c.getDir(uuid))
        Unit
    }

    suspend fun renameDir(uuid: String, name: String) = wrap {
        val c = requireClient()
        c.updateDirMetadata(c.getDir(uuid), DirectoryMetaChanges(name = name, created = CreatedTime.Keep))
        Unit
    }

    /** Moves a file to Filen's trash (recoverable there), never deletes it permanently. */
    suspend fun trashFile(uuid: String) = wrap {
        val c = requireClient()
        c.trashFile(c.getFile(uuid))
        Unit
    }

    /** Files at the top level of Filen's trash (trashed folders are not unpacked). */
    private val trashed = java.util.concurrent.ConcurrentHashMap<String, File>()

    suspend fun listTrash(): Map<String, Any?> = wrap {
        val c = requireClient()
        val listing = c.listTrash()
        trashed.clear()
        for (f in listing.files) trashed[f.uuid] = f
        mapOf("dirs" to emptyList<Map<String, Any?>>(), "files" to listing.files.mapNotNull { fileMap(it, "") })
    }

    /** Puts a trashed file back where it was. */
    suspend fun restoreFile(uuid: String) = wrap {
        val c = requireClient()
        c.restoreFile(trashed[uuid] ?: c.getFile(uuid))
        trashed.remove(uuid)
        Unit
    }

    /** Permanently deletes the contents of Filen's trash. */
    suspend fun emptyTrash() = wrap {
        requireClient().emptyTrash()
        trashed.clear()
    }

    suspend fun moveFile(uuid: String, newParentUuid: String) = wrap {
        val c = requireClient()
        c.moveFile(c.getFile(uuid), dirTarget(c, newParentUuid))
        Unit
    }

    /** WebP thumbnail bytes, or null when the SDK cannot make one for this file. */
    suspend fun thumbnail(uuid: String, maxWidth: Int, maxHeight: Int): ByteArray? = wrap {
        val c = requireClient()
        val file = c.getFile(uuid)
        val result = c.makeThumbnailInMemory(
            MakeThumbnailInMemoryParams(
                file = AnyFile.File(file),
                maxWidth = maxWidth.toUInt(),
                maxHeight = maxHeight.toUInt(),
                lossyQuality = 80.toUByte(),
            ),
        )
        when (result) {
            is MakeThumbnailInMemoryResult.Thumbnail -> result.thumbnail.webpData
            else -> null
        }
    }

    suspend fun uploadFile(
        localPath: String,
        parentUuid: String,
        name: String?,
        createdMs: Long?,
        modifiedMs: Long?,
        mime: String?,
    ): Map<String, Any?> = wrap {
        val c = requireClient()
        val file = c.uploadFile(
            FileBuilderParamsOptionalName(
                parent = dirTarget(c, parentUuid),
                name = name,
                created = createdMs,
                modified = modifiedMs,
                mime = mime,
            ),
            localPath,
            null,
            ManagedFuture(null, null),
        )
        fileMap(file, parentUuid) ?: throw FilenException("INTERNAL", "uploaded file has no readable metadata")
    }

    private fun dirName(meta: DirMeta): String? = (meta as? DirMeta.Decoded)?.v1?.name

    /** Null when the SDK could not decrypt the file's metadata (such a file is not displayable). */
    private fun fileMap(f: File, parentUuid: String): Map<String, Any?>? {
        val m = (f.meta as? FileMeta.Decoded)?.v1 ?: return null
        return mapOf(
            "uuid" to f.uuid,
            "parent" to parentUuid,
            "name" to m.name,
            "mime" to m.mime,
            "size" to f.size.toLong(),
            "created" to m.created,
            "modified" to m.modified,
            "canMakeThumbnail" to f.canMakeThumbnail,
        )
    }

    private inline fun <T> wrap(block: () -> T): T = try {
        block()
    } catch (e: FilenException) {
        throw e
    } catch (e: FilenSdkException) {
        throw FilenException(codeOf(e), e.innerMessage() ?: e.message)
    }

    private fun codeOf(e: FilenSdkException): String = when (e.kind()) {
        ErrorKind.ENTER2FA -> "TWO_FACTOR_REQUIRED"
        ErrorKind.WRONG2FA -> "TWO_FACTOR_WRONG"
        ErrorKind.EMAIL_OR_PASSWORD_WRONG, ErrorKind.WRONG_PASSWORD -> "BAD_CREDENTIALS"
        ErrorKind.UNAUTHENTICATED -> "UNAUTHENTICATED"
        ErrorKind.MAX_STORAGE_REACHED -> "STORAGE_FULL"
        ErrorKind.REQWEST, ErrorKind.RETRY_FAILED -> "NETWORK"
        ErrorKind.FILE_NOT_FOUND, ErrorKind.FOLDER_NOT_FOUND -> "NOT_FOUND"
        ErrorKind.CANCELLED -> "CANCELLED"
        else -> "SDK_ERROR"
    }

    private fun serialize(s: StringifiedClient): String = JSONObject().apply {
        put("email", s.email)
        put("userId", s.userId.toLong())
        put("rootUuid", s.rootUuid)
        put("authInfo", s.authInfo)
        put("privateKey", s.privateKey)
        put("apiKey", s.apiKey)
        put("authVersion", s.authVersion.toInt())
        s.maxParallelRequests?.let { put("maxParallelRequests", it.toLong()) }
        s.maxIoMemoryUsage?.let { put("maxIoMemoryUsage", it.toLong()) }
    }.toString()

    private fun deserialize(json: String): StringifiedClient {
        val o = JSONObject(json)
        return StringifiedClient(
            email = o.getString("email"),
            userId = o.getLong("userId").toULong(),
            rootUuid = o.getString("rootUuid"),
            authInfo = o.getString("authInfo"),
            privateKey = o.getString("privateKey"),
            apiKey = o.getString("apiKey"),
            authVersion = o.getInt("authVersion").toUByte(),
            maxParallelRequests = if (o.has("maxParallelRequests")) o.getLong("maxParallelRequests").toUInt() else null,
            maxIoMemoryUsage = if (o.has("maxIoMemoryUsage")) o.getLong("maxIoMemoryUsage").toUInt() else null,
        )
    }
}
