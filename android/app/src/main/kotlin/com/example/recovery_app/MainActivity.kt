package com.example.recovery_app

import android.Manifest
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.example.recovery_app/permissions"
    private val STORAGE_PERM_CODE = 1001
    private var permResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkStoragePermission" -> {
                    result.success(hasStoragePermission())
                }
                "requestStoragePermission" -> {
                    permResult = result
                    requestStoragePermission()
                }
                // ── MediaStore scan: returns list of maps {n,p,t,s,m} ──
                "scanMediaStore" -> {
                    Thread {
                        try {
                            val files = scanAllMediaStore()
                            runOnUiThread { result.success(files) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("SCAN_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }

                // ── Deleted files scan ──
                // Returns trashed + pending items from MediaStore (Android 10+).
                // On older Android, returns an empty list (isolate handles it).
                "scanDeletedFiles" -> {
                    Thread {
                        try {
                            val files = scanDeletedMediaStore()
                            runOnUiThread { result.success(files) }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(listOf<Map<String, Any>>()) }
                        }
                    }.start()
                }

                // ── Live paths set ──
                // Returns the set of all file paths currently in MediaStore
                // (non-trashed, non-pending). Used by Dart to cross-reference
                // and exclude live files from the filesystem scan.
                "getLivePaths" -> {
                    Thread {
                        try {
                            val paths = getAllLivePaths()
                            runOnUiThread { result.success(paths) }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(listOf<String>()) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    // ── FIXED: Check order matters — TIRAMISU (33) > R (30) ──
    // Must check higher SDK versions FIRST, otherwise Android 13
    // falls into the `>= R` branch and uses isExternalStorageManager().
    private fun hasStoragePermission(): Boolean {
        return when {
            // Android 13+ (API 33+): granular media permissions
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                ContextCompat.checkSelfPermission(
                    this, Manifest.permission.READ_MEDIA_IMAGES
                ) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(
                    this, Manifest.permission.READ_MEDIA_VIDEO
                ) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(
                    this, Manifest.permission.READ_MEDIA_AUDIO
                ) == PackageManager.PERMISSION_GRANTED
            }
            // Android 11-12 (API 30-32): MANAGE_EXTERNAL_STORAGE
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                Environment.isExternalStorageManager()
            }
            // Android 6-10 (API 23-29)
            else -> {
                ContextCompat.checkSelfPermission(
                    this, Manifest.permission.READ_EXTERNAL_STORAGE
                ) == PackageManager.PERMISSION_GRANTED
            }
        }
    }

    private fun requestStoragePermission() {
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                // Android 13+: request granular media permissions
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(
                        Manifest.permission.READ_MEDIA_IMAGES,
                        Manifest.permission.READ_MEDIA_VIDEO,
                        Manifest.permission.READ_MEDIA_AUDIO
                    ),
                    STORAGE_PERM_CODE
                )
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                // Android 11-12: MANAGE_EXTERNAL_STORAGE via settings
                if (!Environment.isExternalStorageManager()) {
                    try {
                        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                        intent.data = Uri.parse("package:$packageName")
                        startActivityForResult(intent, STORAGE_PERM_CODE)
                    } catch (e: Exception) {
                        val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        startActivityForResult(intent, STORAGE_PERM_CODE)
                    }
                } else {
                    permResult?.success(true)
                    permResult = null
                }
            }
            else -> {
                // Android 6-10
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE
                    ),
                    STORAGE_PERM_CODE
                )
            }
        }
    }

    // ── MediaStore full scan ──
    // Queries Images, Video, Audio collections and returns proper file info.
    // This is the correct modern Android way to find media files.
    private fun scanAllMediaStore(): List<Map<String, Any>> {
        val result = mutableListOf<Map<String, Any>>()

        // ── Images ──
        val imgUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        queryMedia(imgUri, "image", result)

        // ── Videos ──
        val vidUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        queryMedia(vidUri, "video", result)

        // ── Audio ──
        val audUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }
        queryMedia(audUri, "audio", result)

        // ── Documents (API 29+) ──
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val docUri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
                queryDocuments(docUri, result)
            } catch (e: Exception) {
                // Documents query not supported on this device/version — ignore
            }
        }

        return result
    }

    private fun queryMedia(
        uri: Uri,
        type: String,
        out: MutableList<Map<String, Any>>
    ) {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.MIME_TYPE
        )

        // Exclude 0-byte files and .thumbnails
        val selection = "${MediaStore.MediaColumns.SIZE} > 0"

        try {
            contentResolver.query(uri, projection, selection, null, "${MediaStore.MediaColumns.DATE_MODIFIED} DESC")
                ?.use { cursor ->
                    val idCol   = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                    val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                    val dataCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                    val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                    val dateCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)

                    while (cursor.moveToNext()) {
                        val id   = cursor.getLong(idCol)
                        val name = cursor.getString(nameCol) ?: continue
                        val size = cursor.getLong(sizeCol)
                        val date = cursor.getLong(dateCol) * 1000L // seconds → ms

                        // Prefer DATA path; fall back to content URI string
                        val path: String = if (dataCol >= 0) {
                            cursor.getString(dataCol) ?: ContentUris.withAppendedId(uri, id).toString()
                        } else {
                            ContentUris.withAppendedId(uri, id).toString()
                        }

                        // Skip thumbnail / cache junk
                        if (isJunkPath(path)) continue

                        out.add(mapOf(
                            "n" to name,
                            "p" to path,
                            "t" to type,
                            "s" to size,
                            "m" to date
                        ))
                    }
                }
        } catch (e: Exception) {
            // Query failed — ignore silently
        }
    }

    private fun queryDocuments(uri: Uri, out: MutableList<Map<String, Any>>) {
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.DATA,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.MIME_TYPE
        )

        val docMimes = arrayOf(
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-powerpoint",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "text/plain",
            "text/csv"
        )

        val placeholders = docMimes.joinToString(",") { "?" }
        val selection = "${MediaStore.Files.FileColumns.MIME_TYPE} IN ($placeholders) AND ${MediaStore.Files.FileColumns.SIZE} > 0"

        try {
            contentResolver.query(uri, projection, selection, docMimes, "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC")
                ?.use { cursor ->
                    val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
                    val dataCol = cursor.getColumnIndex(MediaStore.Files.FileColumns.DATA)
                    val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                    val dateCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)

                    while (cursor.moveToNext()) {
                        val name = cursor.getString(nameCol) ?: continue
                        val size = cursor.getLong(sizeCol)
                        val date = cursor.getLong(dateCol) * 1000L
                        val path: String = if (dataCol >= 0) cursor.getString(dataCol) ?: continue else continue

                        if (isJunkPath(path)) continue

                        out.add(mapOf(
                            "n" to name,
                            "p" to path,
                            "t" to "document",
                            "s" to size,
                            "m" to date
                        ))
                    }
                }
        } catch (e: Exception) {
            // Query failed — ignore silently
        }
    }

    // ── Deleted / trashed MediaStore entries (Android 10+) ──
    private fun scanDeletedMediaStore(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return out

        val uris = listOf(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL) to "image",
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)  to "video",
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)  to "audio"
        )

        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED
        )

        for ((uri, type) in uris) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    // Android 11+: Bundle query with match-trashed
                    val bundle = android.os.Bundle().apply {
                        putInt("android:query-arg-match-trashed", 1)
                        putInt("android:query-arg-match-pending", 1)
                        putString(
                            "android:query-arg-sql-selection",
                            "${MediaStore.MediaColumns.IS_TRASHED} = 1 OR ${MediaStore.MediaColumns.IS_PENDING} = 1"
                        )
                    }
                    contentResolver.query(uri, projection, bundle, null)
                } else {
                    // Android 10 (Q): only pending items accessible without special flag
                    contentResolver.query(
                        uri, projection,
                        "${MediaStore.MediaColumns.IS_PENDING} = 1",
                        null,
                        "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"
                    )
                }?.use { c ->
                    val idCol   = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                    val nameCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                    val dataCol = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                    val sizeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                    val dateCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                    while (c.moveToNext()) {
                        val id   = c.getLong(idCol)
                        val name = c.getString(nameCol) ?: continue
                        val size = c.getLong(sizeCol)
                        if (size <= 0) continue
                        val date = c.getLong(dateCol) * 1000L
                        val path = if (dataCol >= 0) {
                            c.getString(dataCol) ?: ContentUris.withAppendedId(uri, id).toString()
                        } else {
                            ContentUris.withAppendedId(uri, id).toString()
                        }
                        out.add(mapOf("n" to name, "p" to path, "t" to type, "s" to size, "m" to date, "del" to true))
                    }
                }
            } catch (e: Exception) { /* uri unsupported — skip */ }
        }

        // Deleted documents (API 30+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val docUri  = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
                val docMimes = arrayOf(
                    "application/pdf",
                    "application/msword",
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    "application/vnd.ms-excel",
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    "text/plain"
                )
                val ph = docMimes.joinToString(",") { "?" }
                val bundle = android.os.Bundle().apply {
                    putInt("android:query-arg-match-trashed", 1)
                    putInt("android:query-arg-match-pending", 1)
                    putString(
                        "android:query-arg-sql-selection",
                        "(${MediaStore.Files.FileColumns.IS_TRASHED} = 1 OR ${MediaStore.Files.FileColumns.IS_PENDING} = 1)" +
                        " AND ${MediaStore.Files.FileColumns.MIME_TYPE} IN ($ph)" +
                        " AND ${MediaStore.Files.FileColumns.SIZE} > 0"
                    )
                    putStringArray("android:query-arg-sql-selection-args", docMimes)
                }
                val docProj = arrayOf(
                    MediaStore.Files.FileColumns.DISPLAY_NAME,
                    MediaStore.Files.FileColumns.DATA,
                    MediaStore.Files.FileColumns.SIZE,
                    MediaStore.Files.FileColumns.DATE_MODIFIED
                )
                contentResolver.query(docUri, docProj, bundle, null)?.use { c ->
                    val nameCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
                    val dataCol = c.getColumnIndex(MediaStore.Files.FileColumns.DATA)
                    val sizeCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
                    val dateCol = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
                    while (c.moveToNext()) {
                        val name = c.getString(nameCol) ?: continue
                        val size = c.getLong(sizeCol)
                        if (size <= 0) continue
                        val date = c.getLong(dateCol) * 1000L
                        val path = if (dataCol >= 0) c.getString(dataCol) ?: continue else continue
                        out.add(mapOf("n" to name, "p" to path, "t" to "document", "s" to size, "m" to date, "del" to true))
                    }
                }
            } catch (e: Exception) { /* ignore */ }
        }

        return out
    }

    // ── All live (non-deleted) file paths from MediaStore ──
    // Returns a flat List<String> of all paths currently in MediaStore
    // that are NOT trashed and NOT pending.
    // Dart uses this to subtract live files from the filesystem scan,
    // leaving only orphaned/deleted files.
    private fun getAllLivePaths(): List<String> {
        val paths = mutableListOf<String>()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return paths

        val uris = listOf(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL),
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL),
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        )

        val projection = arrayOf(MediaStore.MediaColumns.DATA)

        for (uri in uris) {
            try {
                val selection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    "${MediaStore.MediaColumns.IS_PENDING} = 0"
                } else null

                contentResolver.query(uri, projection, selection, null, null)
                    ?.use { c ->
                        val col = c.getColumnIndex(MediaStore.MediaColumns.DATA)
                        if (col < 0) return@use
                        while (c.moveToNext()) {
                            val p = c.getString(col) ?: continue
                            if (p.isNotEmpty()) paths.add(p)
                        }
                    }
            } catch (e: Exception) { /* ignore */ }
        }
        return paths
    }

    // Filters out known junk paths that pollute results
    private fun isJunkPath(path: String): Boolean {
        val lower = path.lowercase()
        return lower.contains("/.thumbnails/") ||
               lower.contains("/thumbnails/") ||
               lower.contains("/.trash/") ||
               lower.contains("/cache/") ||
               lower.contains("/.cache/") ||
               lower.contains("/android/data/com.") ||
               lower.contains("/android/obb/") ||
               lower.contains("/.android_secure/") ||
               lower.contains("/lost+found/") ||
               lower.contains("/.nomedia") ||
               lower.endsWith(".tmp") ||
               lower.endsWith(".partial") ||
               lower.endsWith(".crdownload")
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == STORAGE_PERM_CODE) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults.any { it == PackageManager.PERMISSION_GRANTED }
            permResult?.success(granted)
            permResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == STORAGE_PERM_CODE) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val granted = Environment.isExternalStorageManager()
                permResult?.success(granted)
                permResult = null
            }
        }
    }
}
