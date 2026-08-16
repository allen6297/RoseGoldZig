package org.rosegold.ide.debug;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * A minimal Debug Adapter Protocol client: it frames requests to (and parses
 * responses/events from) a `RoseGold_Zig dap` process over stdio. A background
 * reader thread dispatches responses to their per-`seq` callback and events to
 * the {@link EventListener}. See {@link #frame} / {@link #splitMessages} for the
 * (unit-tested) wire framing.
 */
public final class DapClient {
    /** Notified for each DAP event (`stopped`, `output`, `terminated`, …). */
    public interface EventListener {
        void onEvent(String event, JsonObject body);
        default void onClosed() {}
    }

    /** Called with a response body when the matching request completes. */
    public interface ResponseHandler {
        void onResponse(boolean success, JsonObject body);
    }

    private final OutputStream out;
    private final InputStream in;
    private final EventListener listener;
    private final AtomicInteger seq = new AtomicInteger(1);
    private final ConcurrentHashMap<Integer, ResponseHandler> pending = new ConcurrentHashMap<>();
    private volatile boolean closed = false;

    public DapClient(InputStream in, OutputStream out, EventListener listener) {
        this.in = in;
        this.out = out;
        this.listener = listener;
    }

    public void start() {
        Thread t = new Thread(this::readLoop, "rosegold-dap-reader");
        t.setDaemon(true);
        t.start();
    }

    /** Send a request with the given arguments; `handler` (may be null) gets the reply. */
    public synchronized void send(String command, JsonObject arguments, ResponseHandler handler) {
        if (closed) {
            return;
        }
        int s = seq.getAndIncrement();
        JsonObject req = new JsonObject();
        req.addProperty("seq", s);
        req.addProperty("type", "request");
        req.addProperty("command", command);
        if (arguments != null) {
            req.add("arguments", arguments);
        }
        if (handler != null) {
            pending.put(s, handler);
        }
        try {
            out.write(frame(req.toString()));
            out.flush();
        } catch (IOException e) {
            close();
        }
    }

    public void send(String command, JsonObject arguments) {
        send(command, arguments, null);
    }

    public void close() {
        closed = true;
        try {
            in.close();
        } catch (IOException ignored) {
        }
    }

    // --- reader ---------------------------------------------------------------

    private void readLoop() {
        try {
            while (!closed) {
                JsonObject msg = readMessage();
                if (msg == null) {
                    break;
                }
                dispatch(msg);
            }
        } catch (IOException ignored) {
            // stream closed
        } finally {
            listener.onClosed();
        }
    }

    private void dispatch(JsonObject msg) {
        String type = str(msg, "type");
        if ("response".equals(type)) {
            int reqSeq = intOr(msg, "request_seq", -1);
            ResponseHandler h = pending.remove(reqSeq);
            if (h != null) {
                boolean ok = !msg.has("success") || msg.get("success").getAsBoolean();
                JsonObject body = msg.has("body") && msg.get("body").isJsonObject() ? msg.getAsJsonObject("body") : new JsonObject();
                h.onResponse(ok, body);
            }
        } else if ("event".equals(type)) {
            JsonObject body = msg.has("body") && msg.get("body").isJsonObject() ? msg.getAsJsonObject("body") : new JsonObject();
            listener.onEvent(str(msg, "event"), body);
        }
    }

    /** Read one Content-Length-framed JSON message, or null at end of stream. */
    private JsonObject readMessage() throws IOException {
        int contentLength = -1;
        StringBuilder line = new StringBuilder();
        while (true) {
            int c = in.read();
            if (c == -1) {
                return null;
            }
            if (c == '\n') {
                String header = line.toString().trim();
                line.setLength(0);
                if (header.isEmpty()) {
                    break; // end of headers
                }
                if (header.regionMatches(true, 0, "Content-Length:", 0, "Content-Length:".length())) {
                    try {
                        contentLength = Integer.parseInt(header.substring("Content-Length:".length()).trim());
                    } catch (NumberFormatException ignored) {
                    }
                }
            } else if (c != '\r') {
                line.append((char) c);
            }
        }
        if (contentLength < 0) {
            return null;
        }
        byte[] body = in.readNBytes(contentLength);
        JsonElement el = JsonParser.parseString(new String(body, StandardCharsets.UTF_8));
        return el.isJsonObject() ? el.getAsJsonObject() : new JsonObject();
    }

    // --- wire framing (static, unit-tested) -----------------------------------

    /** Frame a JSON payload with a DAP `Content-Length` header. */
    public static byte[] frame(String json) {
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        byte[] header = ("Content-Length: " + body.length + "\r\n\r\n").getBytes(StandardCharsets.US_ASCII);
        byte[] out = new byte[header.length + body.length];
        System.arraycopy(header, 0, out, 0, header.length);
        System.arraycopy(body, 0, out, header.length, body.length);
        return out;
    }

    /** Parse a buffer of concatenated framed messages into their JSON bodies. */
    public static JsonArray splitMessages(byte[] data) {
        JsonArray out = new JsonArray();
        int i = 0;
        while (i < data.length) {
            int hdrEnd = indexOf(data, "\r\n\r\n".getBytes(StandardCharsets.US_ASCII), i);
            if (hdrEnd < 0) {
                break;
            }
            String header = new String(data, i, hdrEnd - i, StandardCharsets.US_ASCII);
            int n = 0;
            for (String h : header.split("\r\n")) {
                if (h.regionMatches(true, 0, "Content-Length:", 0, 15)) {
                    n = Integer.parseInt(h.substring(15).trim());
                }
            }
            int bodyStart = hdrEnd + 4;
            if (bodyStart + n > data.length) {
                break;
            }
            out.add(JsonParser.parseString(new String(data, bodyStart, n, StandardCharsets.UTF_8)));
            i = bodyStart + n;
        }
        return out;
    }

    private static int indexOf(byte[] hay, byte[] needle, int from) {
        outer:
        for (int i = from; i <= hay.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    continue outer;
                }
            }
            return i;
        }
        return -1;
    }

    static String str(JsonObject o, String k) {
        return o.has(k) && o.get(k).isJsonPrimitive() ? o.get(k).getAsString() : "";
    }

    static int intOr(JsonObject o, String k, int def) {
        return o.has(k) && o.get(k).isJsonPrimitive() ? o.get(k).getAsInt() : def;
    }
}
