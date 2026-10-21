package io.github.wasanyang.lumen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class AdBlockTest {
    /** The real shared/blocklist.txt, so a bad edit there fails here too. */
    private val blocklist = AdBlock.parse(File("../../shared/blocklist.txt").readText())

    @Test fun blocksAdURLs() {
        for (url in listOf(
            "https://securepubads.g.doubleclick.net/tag/js/gpt.js",
            "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
            "https://www.googleadservices.com/pagead/conversion.js",
            "https://c.amazon-adsystem.com/aax2/apstag.js",
            "https://www.youtube.com/pagead/viewthroughconversion/0/",
            "https://m.youtube.com/api/stats/ads?ver=2",
            "https://www.youtube.com/ptracking?pltype=content",
            "https://DOUBLECLICK.NET:443/x",
        )) assertTrue(url, blocklist.blocks(url))
    }

    @Test fun letsNormalURLsThrough() {
        for (url in listOf(
            "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            "https://m.youtube.com/",
            "https://rr1---sn-abc.googlevideo.com/videoplayback?expire=1",
            "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
            "https://www.youtube.com/api/stats/watchtime?ns=yt",
            "https://notdoubleclick.net/",
            "https://example.com/?u=doubleclick.net",
        )) assertFalse(url, blocklist.blocks(url))
    }

    @Test fun hostOf() {
        assertEquals("www.youtube.com", AdBlock.hostOf("https://www.YouTube.com/watch?v=1"))
        assertEquals("example.com", AdBlock.hostOf("https://user:pw@example.com:8080/a"))
        assertEquals("example.com", AdBlock.hostOf("https://example.com?x=1"))
        assertEquals(null, AdBlock.hostOf("about:blank"))
    }

    @Test fun versionsCompareNumberByNumber() {
        assertTrue(UBOLite.isOlder("2026.1018.2229", "2026.1020.1"))
        assertTrue(UBOLite.isOlder("2026.9.1", "2026.10.1"))
        assertTrue(UBOLite.isOlder("1.2", "1.2.0"))
        assertFalse(UBOLite.isOlder("2026.1020.1", "2026.1020.1"))
    }
}
