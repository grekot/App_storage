package pl.grekot.sklep

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import io.flutter.plugin.common.MethodChannel

/**
 * Oczekujące instalacje: sessionId -> Future po stronie Darta.
 * Wszystkie wywołania idą w wątku głównym (rejestracja przez Handler, odbiornik też w main).
 */
object InstallCallbacks {
    var activity: Activity? = null
    private val pending = HashMap<Int, MethodChannel.Result>()

    fun register(sessionId: Int, result: MethodChannel.Result) {
        pending[sessionId] = result
    }

    /** status: success | aborted | conflict | incompatible | storage | blocked | invalid | failure */
    fun finish(sessionId: Int, status: String, message: String?) {
        val r = pending.remove(sessionId) ?: return
        r.success(mapOf("status" to status, "message" to message))
    }
}

/** Odbiera wynik sesji PackageInstaller (PendingIntent z MainActivity.install). */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // System chce potwierdzenia użytkownika – pokazujemy jego okno.
                val confirm = confirmIntent(intent) ?: run {
                    InstallCallbacks.finish(sessionId, "failure", "Brak okna potwierdzenia instalacji")
                    return
                }
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                (InstallCallbacks.activity ?: context).startActivity(confirm)
            }
            PackageInstaller.STATUS_SUCCESS -> InstallCallbacks.finish(sessionId, "success", null)
            PackageInstaller.STATUS_FAILURE_ABORTED -> InstallCallbacks.finish(sessionId, "aborted", message)
            PackageInstaller.STATUS_FAILURE_CONFLICT -> InstallCallbacks.finish(sessionId, "conflict", message)
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> InstallCallbacks.finish(sessionId, "incompatible", message)
            PackageInstaller.STATUS_FAILURE_STORAGE -> InstallCallbacks.finish(sessionId, "storage", message)
            PackageInstaller.STATUS_FAILURE_BLOCKED -> InstallCallbacks.finish(sessionId, "blocked", message)
            PackageInstaller.STATUS_FAILURE_INVALID -> InstallCallbacks.finish(sessionId, "invalid", message)
            else -> InstallCallbacks.finish(sessionId, "failure", message)
        }
    }

    @Suppress("DEPRECATION")
    private fun confirmIntent(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_INTENT)

    companion object {
        const val ACTION = "pl.grekot.sklep.INSTALL_RESULT"
    }
}
