package io.github.wasanyang.lumen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState

/**
 * Keeps Lumen running while music plays with the screen off or another app in front: without a foreground
 * service Android freezes a background app, web view included. It also puts the song on the lock screen and
 * in the notification shade, with a play/pause button that drives the page through `controller`.
 * MainActivity starts it when a video starts playing while Lumen is on screen, and stops it when Lumen is
 * back on screen with nothing playing.
 */
class PlaybackService : Service() {
    companion object {
        private const val CHANNEL = "playback"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_TOGGLE = "io.github.wasanyang.lumen.TOGGLE"
        private const val EXTRA_TITLE = "title"

        /** Runs "play" or "pause" in the page; set by MainActivity while it exists. */
        var controller: ((String) -> Unit)? = null

        var instance: PlaybackService? = null
            private set

        fun start(context: Context, title: String) {
            context.startForegroundService(Intent(context, PlaybackService::class.java).putExtra(EXTRA_TITLE, title))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }

    private lateinit var session: MediaSession
    private var playing = true
    private var title = ""
    private var foreground = false

    override fun onBind(intent: Intent?) = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Playing", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        session = MediaSession(this, "Lumen").apply {
            setCallback(object : MediaSession.Callback() {
                // Qualified: inside MediaSession, a bare `controller` is the session's own MediaController.
                override fun onPlay() { PlaybackService.controller?.invoke("play") }
                override fun onPause() { PlaybackService.controller?.invoke("pause") }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_TOGGLE) {
            controller?.invoke(if (playing) "pause" else "play")
            if (!foreground) show(playing, title)
        } else {
            show(true, intent?.getStringExtra(EXTRA_TITLE).orEmpty())
        }
        return START_NOT_STICKY
    }

    /** Updates the lock screen and notification; the first call makes the service a foreground one. */
    fun show(isPlaying: Boolean, newTitle: String) {
        playing = isPlaying
        if (newTitle.isNotEmpty()) title = newTitle
        session.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title.ifEmpty { "YouTube" })
            .putString(MediaMetadata.METADATA_KEY_ARTIST, "YouTube")
            .build())
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE)
            .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f)
            .build())

        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val toggle = PendingIntent.getService(this, 1,
            Intent(this, PlaybackService::class.java).setAction(ACTION_TOGGLE), PendingIntent.FLAG_IMMUTABLE)
        val button = Notification.Action.Builder(
            Icon.createWithResource(this, if (playing) R.drawable.ic_pause else R.drawable.ic_play),
            if (playing) "Pause" else "Play", toggle).build()
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title.ifEmpty { "Lumen" })
            .setContentText("YouTube")
            .setContentIntent(open)
            .setOngoing(playing)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(button)
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0))
            .build()

        if (foreground) {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        } else {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            foreground = true
        }
    }

    /** Swiping Lumen away from recent apps ends the music too. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        controller?.invoke("pause")
        stopSelf()
    }

    override fun onDestroy() {
        instance = null
        session.release()
        super.onDestroy()
    }
}
