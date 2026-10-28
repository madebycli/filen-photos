package io.ente.photos.filen

import org.json.JSONObject
import uniffi.filen_sdk_rs.AnyFile
import uniffi.filen_sdk_rs.AnyNormalDir
import uniffi.filen_sdk_rs.DirMeta
import uniffi.filen_sdk_rs.ErrorKind
import uniffi.filen_sdk_rs.File
import uniffi.filen_sdk_rs.FileBuilderParamsOptionalName
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
class FilenException(val code: String, message: String?) : Exception(message)

/**
 * Thin adapter around Filen's official SDK bindings. It holds the authenticated client and
 * translates the SDK's types into plain maps. No networking or cryptography happens here:
 * everything is delegated to `filen-sdk-rs`.
 */
class FilenBackend {
    @Volatile
    private var client: JsClient? = null

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
            val c = unauth().login(LoginParams(email, password, twoFactorCode?.ifBlank { null }))
            client = c
            serialize(c.toStringified())
        }

    suspend fun restore(session: String) = wrap {
        client = unauth().fromStringified(deserialize(session))
    }

    fun logout() {
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
    suspend fun listTree(rootUuid: String): Map<String, Any?> = wrap {
        val c = requireClient()
        val dirs = ArrayList<Map<String, Any?>>()
        val files = ArrayList<Map<String, Any?>>()
        val queue = ArrayDeque<String>()
        queue.add(rootUuid)
        while (queue.isNotEmpty()) {
            val uuid = queue.removeFirst()
            val listing = c.listDir(dirTarget(c, uuid))
            for (d in listing.dirs) {
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

    /** Moves a file to Filen's trash (recoverable there), never deletes it permanently. */
    suspend fun trashFile(uuid: String) = wrap {
        val c = requireClient()
        c.trashFile(c.getFile(uuid))
        Unit
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
