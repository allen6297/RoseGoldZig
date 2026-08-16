package org.rosegold.ide;

import com.google.gson.JsonArray;
import org.junit.Test;
import org.rosegold.ide.debug.DapClient;

import java.io.ByteArrayOutputStream;
import java.io.IOException;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

/** Unit tests for the DAP client's Content-Length wire framing. */
public class DapClientTest {

    @Test
    public void frameHasContentLengthHeader() {
        byte[] framed = DapClient.frame("{\"a\":1}"); // 7-byte body
        String s = new String(framed);
        assertTrue(s, s.startsWith("Content-Length: 7\r\n\r\n"));
        assertTrue(s.endsWith("{\"a\":1}"));
    }

    @Test
    public void splitOneMessage() {
        JsonArray msgs = DapClient.splitMessages(DapClient.frame("{\"a\":1}"));
        assertEquals(1, msgs.size());
        assertEquals(1, msgs.get(0).getAsJsonObject().get("a").getAsInt());
    }

    @Test
    public void splitTwoConcatenatedMessages() throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        buf.write(DapClient.frame("{\"x\":\"hi\"}"));
        buf.write(DapClient.frame("{\"y\":2}"));
        JsonArray msgs = DapClient.splitMessages(buf.toByteArray());
        assertEquals(2, msgs.size());
        assertEquals("hi", msgs.get(0).getAsJsonObject().get("x").getAsString());
        assertEquals(2, msgs.get(1).getAsJsonObject().get("y").getAsInt());
    }

    @Test
    public void utf8BodyLengthIsByteCount() {
        // "é" is 2 UTF-8 bytes, so the header must count bytes, not chars.
        byte[] framed = DapClient.frame("{\"s\":\"é\"}");
        JsonArray msgs = DapClient.splitMessages(framed);
        assertEquals(1, msgs.size());
        assertEquals("é", msgs.get(0).getAsJsonObject().get("s").getAsString());
    }
}
