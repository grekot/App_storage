package pl.grekot.sklep

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Kanał `pl.grekot.sklep/installer` – wszystko, czego Flutter nie umie sam:
 *  - `installed(packages)`  wersja i podpis zainstalowanych aplikacji,
 *  - `self()`               to samo dla sklepu (w tym odcisk naszego klucza podpisu),
 *  - `apkInfo(path)`        pakiet, wersja i podpis pobranego pliku APK,
 *  - `canInstall()` / `openInstallSettings()`  zgoda "Instaluj nieznane aplikacje",
 *  - `install(path)`        instalacja przez PackageInstaller; Future kończy się wynikiem,
 *  - `launch(pkg)`, `uninstall(pkg)`,
 *  - `takeLink()`           link grekot-sklep://… z którym uruchomiono sklep
 *                           (kolejne linki przychodzą wywołaniem `link` do Darta).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLink = linkOf(intent)
        InstallCallbacks.activity = this
        createNotificationChannel()
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "installed" -> {
                        val pkgs = call.argument<List<String>>("packages") ?: emptyList()
                        val out = HashMap<String, Map<String, Any?>>()
                        for (p in pkgs) installedInfo(p)?.let { out[p] = it }
                        result.success(out)
                    }
                    "self" -> result.success(installedInfo(packageName))
                    "apkInfo" -> result.success(apkInfo(call.argument("path") ?: ""))
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls()
                    )
                    "openInstallSettings" -> {
                        val i = if (Build.VERSION.SDK_INT >= 26) {
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                        } else {
                            Intent(Settings.ACTION_SECURITY_SETTINGS)
                        }
                        startActivity(i)
                        result.success(true)
                    }
                    "install" -> install(call.argument("path") ?: "", result)
                    "launch" -> {
                        val i = packageManager.getLaunchIntentForPackage(call.argument("package") ?: "")
                        if (i != null) startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(i != null)
                    }
                    "uninstall" -> {
                        val pkg: String = call.argument("package") ?: ""
                        startActivity(Intent(Intent.ACTION_DELETE, Uri.parse("package:$pkg")))
                        result.success(true)
                    }
                    "takeLink" -> {
                        result.success(pendingLink)
                        pendingLink = null
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("installer", e.message, null)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = linkOf(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("link", link) else pendingLink = link
    }

    override fun onDestroy() {
        if (InstallCallbacks.activity === this) InstallCallbacks.activity = null
        super.onDestroy()
    }

    /** Kanał powiadomień FCM o nowych wersjach (nazwa w AndroidManifest.xml). */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel("nowe_wersje", "Nowe wersje aplikacji", NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    private fun linkOf(i: Intent?): String? =
        if (i?.action == Intent.ACTION_VIEW && i.data?.scheme == "grekot-sklep") i.dataString else null

    // ---------------------------------------------------------------- wersje i podpisy

    @Suppress("DEPRECATION")
    private fun installedInfo(pkg: String): Map<String, Any?>? {
        val info = try {
            packageManager.getPackageInfo(pkg, signingFlags())
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        }
        return describe(info)
    }

    @Suppress("DEPRECATION")
    private fun apkInfo(path: String): Map<String, Any?>? {
        require(File(path).exists()) { "Plik nie istnieje: $path" }
        val info = packageManager.getPackageArchiveInfo(path, signingFlags()) ?: return null
        return describe(info)
    }

    @Suppress("DEPRECATION")
    private fun signingFlags(): Int =
        if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
        else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun describe(info: PackageInfo): Map<String, Any?> {
        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        val certs = if (Build.VERSION.SDK_INT >= 28) {
            val s = info.signingInfo
            when {
                s == null -> null
                s.hasMultipleSigners() -> s.apkContentsSigners
                // historia rotacji: bieżący certyfikat jest na końcu
                else -> s.signingCertificateHistory?.lastOrNull()?.let { arrayOf(it) }
            }
        } else {
            info.signatures
        }
        val signer = certs?.firstOrNull()?.toByteArray()?.let { sha256Hex(it) }
        return mapOf(
            "packageName" to info.packageName,
            "versionName" to (info.versionName ?: ""),
            "versionCode" to code,
            "signerSha256" to signer,
        )
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    // ---------------------------------------------------------------- instalacja

    private fun install(path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (!file.exists()) {
            result.error("installer", "Plik nie istnieje: $path", null)
            return
        }
        io.execute {
            var sessionId = -1
            try {
                val installer = packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                if (Build.VERSION.SDK_INT >= 26) {
                    params.setInstallReason(PackageManager.INSTALL_REASON_USER)
                }
                if (Build.VERSION.SDK_INT >= 31) {
                    // Działa tylko dla aktualizacji aplikacji zainstalowanych przez sklep;
                    // w pozostałych przypadkach system i tak poprosi o potwierdzenie.
                    params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                }
                val id = installer.createSession(params)
                sessionId = id
                main.post { InstallCallbacks.register(id, result) }
                installer.openSession(sessionId).use { session ->
                    file.inputStream().use { input ->
                        session.openWrite("base.apk", 0, file.length()).use { out ->
                            input.copyTo(out)
                            session.fsync(out)
                        }
                    }
                    val intent = Intent(this, InstallResultReceiver::class.java)
                        .setAction(InstallResultReceiver.ACTION)
                    var flags = PendingIntent.FLAG_UPDATE_CURRENT
                    if (Build.VERSION.SDK_INT >= 31) flags = flags or PendingIntent.FLAG_MUTABLE
                    val pending = PendingIntent.getBroadcast(this, id, intent, flags)
                    session.commit(pending.intentSender)
                }
            } catch (e: Exception) {
                val id = sessionId
                val msg = e.message ?: e.toString()
                main.post {
                    if (id >= 0) InstallCallbacks.finish(id, "failure", msg)
                    else result.error("installer", msg, null)
                }
            }
        }
    }

    companion object {
        const val CHANNEL = "pl.grekot.sklep/installer"
    }
}
