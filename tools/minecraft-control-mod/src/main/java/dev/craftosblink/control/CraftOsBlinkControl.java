package dev.craftosblink.control;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import com.mojang.blaze3d.platform.NativeImage;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.network.chat.Component;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;
import org.lwjgl.glfw.GLFW;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.Supplier;

/**
 * Deliberately tiny local automation bridge used to produce and verify the
 * in-game guide. It is client-only and listens on the IPv4 loopback interface.
 */
public final class CraftOsBlinkControl implements ClientModInitializer {
    private static final int PORT = Integer.getInteger("craftosBlink.controlPort", 8765);
    private static final DateTimeFormatter SCREENSHOT_TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd_HH.mm.ss.SSS");
    private HttpServer server;
    private volatile long lastClientPulse = System.nanoTime();

    @Override
    public void onInitializeClient() {
        try {
            server = HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), PORT), 0);
            server.createContext("/health", checked(this::health));
            server.createContext("/state", checked(this::state));
            server.createContext("/command", checked(this::command));
            server.createContext("/use", checked(this::use));
            server.createContext("/input", checked(this::input));
            server.createContext("/screenshot", checked(this::screenshot));
            server.setExecutor(Executors.newSingleThreadExecutor(runnable -> {
                Thread thread = new Thread(runnable, "craftos-blink-control");
                thread.setDaemon(true);
                return thread;
            }));
            server.start();
            ClientTickEvents.END_CLIENT_TICK.register(client -> lastClientPulse = System.nanoTime());
            ClientLifecycleEvents.CLIENT_STOPPING.register(client -> server.stop(0));
            System.out.println("[CraftOS Blink Control] listening on http://127.0.0.1:" + PORT);
        } catch (IOException exception) {
            throw new IllegalStateException("Could not bind CraftOS Blink control service", exception);
        }
    }

    private void health(HttpExchange exchange) throws Exception {
        requireMethod(exchange, "GET");
        long pulseAgeMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - lastClientPulse);
        respond(exchange, 200, "{\"ok\":true,\"client_pulse_age_ms\":" + pulseAgeMs
            + ",\"client_responsive\":" + (pulseAgeMs < 2000) + "}");
    }

    private void state(HttpExchange exchange) throws Exception {
        requireMethod(exchange, "GET");
        String body = onClient(() -> {
            Minecraft client = Minecraft.getInstance();
            if (client.player == null || client.level == null) {
                return "{\"ready\":false,\"screen\":" + json(client.screen == null ? "none" : client.screen.getClass().getSimpleName()) + "}";
            }
            return "{\"ready\":true,\"player\":" + json(client.player.getGameProfile().getName())
                + ",\"x\":" + client.player.getX() + ",\"y\":" + client.player.getY()
                + ",\"z\":" + client.player.getZ() + ",\"screen\":"
                + json(client.screen == null ? "none" : client.screen.getClass().getSimpleName()) + "}";
        });
        respond(exchange, 200, body);
    }

    private void command(HttpExchange exchange) throws Exception {
        requireMethod(exchange, "POST");
        String command = readBody(exchange).strip();
        if (command.startsWith("/")) command = command.substring(1);
        if (command.isBlank() || command.length() > 2048) throw new BadRequest("Command is empty or too long");
        String finalCommand = command;
        onClient(() -> {
            Minecraft client = Minecraft.getInstance();
            if (client.player == null) throw new IllegalStateException("No player is present");
            client.player.connection.sendCommand(finalCommand);
            return null;
        });
        respond(exchange, 202, "{\"accepted\":true,\"command\":" + json(command) + "}");
    }

    private void use(HttpExchange exchange) throws Exception {
        requireMethod(exchange, "POST");
        Map<String, String> query = query(exchange.getRequestURI());
        int x = integer(query, "x"), y = integer(query, "y"), z = integer(query, "z");
        onClient(() -> {
            Minecraft client = Minecraft.getInstance();
            if (client.player == null || client.gameMode == null) throw new IllegalStateException("No active game");
            BlockPos pos = new BlockPos(x, y, z);
            BlockHitResult hit = new BlockHitResult(Vec3.atCenterOf(pos), Direction.UP, pos, false);
            client.gameMode.useItemOn(client.player, InteractionHand.MAIN_HAND, hit);
            return null;
        });
        respond(exchange, 202, "{\"accepted\":true}");
    }

    private void screenshot(HttpExchange exchange) throws Exception {
        requireMethod(exchange, "POST");
        NativeImage image = onClient(() -> Screenshot.takeScreenshot(Minecraft.getInstance().getMainRenderTarget()));
        Path directory = Minecraft.getInstance().gameDirectory.toPath().resolve("screenshots");
        Files.createDirectories(directory);
        Path output = directory.resolve("craftos-blink-" + LocalDateTime.now().format(SCREENSHOT_TIME) + ".png");
        try { image.writeToFile(output); }
        finally { image.close(); }
        respond(exchange, 200, "{\"saved\":true,\"path\":" + json(output.toString()) + "}");
    }

    private void input(HttpExchange exchange) throws Exception {
        requireMethod(exchange, "POST");
        String input = readBody(exchange);
        Map<String, String> query = query(exchange.getRequestURI());
        boolean clear = Boolean.parseBoolean(query.getOrDefault("clear", "false"));
        boolean submit = Boolean.parseBoolean(query.getOrDefault("submit", "false"));
        onClient(() -> {
            Minecraft client = Minecraft.getInstance();
            Screen screen = client.screen;
            if (screen == null) throw new IllegalStateException("No screen is open");
            if (clear) {
                for (int i = 0; i < 512; i++) {
                    screen.keyPressed(GLFW.GLFW_KEY_BACKSPACE, 0, 0);
                    screen.keyReleased(GLFW.GLFW_KEY_BACKSPACE, 0, 0);
                }
            }
            for (int i = 0; i < input.length(); i++) screen.charTyped(input.charAt(i), 0);
            if (submit) {
                screen.keyPressed(GLFW.GLFW_KEY_ENTER, 0, 0);
                screen.keyReleased(GLFW.GLFW_KEY_ENTER, 0, 0);
            }
            return null;
        });
        respond(exchange, 202, "{\"accepted\":true,\"characters\":" + input.length()
            + ",\"cleared\":" + clear + ",\"submitted\":" + submit + "}");
    }

    private static <T> T onClient(Supplier<T> action) throws Exception {
        Minecraft client = Minecraft.getInstance();
        CompletableFuture<T> result = new CompletableFuture<>();
        client.execute(() -> {
            try { result.complete(action.get()); }
            catch (Throwable throwable) { result.completeExceptionally(throwable); }
        });
        try { return result.get(10, TimeUnit.SECONDS); }
        catch (TimeoutException exception) {
            dumpRenderThread();
            throw new IllegalStateException("Minecraft render-thread task timed out after 10 seconds", exception);
        }
    }

    private static void dumpRenderThread() {
        for (Map.Entry<Thread, StackTraceElement[]> entry : Thread.getAllStackTraces().entrySet()) {
            Thread thread = entry.getKey();
            if (!thread.getName().equals("Render thread")) continue;
            System.err.println("[CraftOS Blink Control] Render thread state: " + thread.getState());
            for (StackTraceElement frame : entry.getValue()) System.err.println("    at " + frame);
        }
    }

    private static HttpHandler checked(ThrowingHandler handler) {
        return exchange -> {
            long started = System.nanoTime();
            String request = exchange.getRequestMethod() + " " + exchange.getRequestURI();
            System.out.println("[CraftOS Blink Control] -> " + request);
            try {
                handler.handle(exchange);
                long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
                System.out.println("[CraftOS Blink Control] <- " + request + " (" + elapsedMs + " ms)");
            } catch (BadRequest exception) {
                System.err.println("[CraftOS Blink Control] bad request " + request + ": " + exception.getMessage());
                respond(exchange, 400, "{\"error\":" + json(exception.getMessage()) + "}");
            } catch (Exception exception) {
                System.err.println("[CraftOS Blink Control] failed " + request + ": " + exception);
                exception.printStackTrace(System.err);
                respond(exchange, 500, "{\"error\":" + json(exception.toString()) + "}");
            }
        };
    }

    private static void requireMethod(HttpExchange exchange, String expected) throws BadRequest {
        if (!exchange.getRequestMethod().equals(expected)) throw new BadRequest("Expected " + expected);
    }

    private static String readBody(HttpExchange exchange) throws IOException {
        return new String(exchange.getRequestBody().readNBytes(8192), StandardCharsets.UTF_8);
    }

    private static Map<String, String> query(URI uri) {
        Map<String, String> result = new HashMap<>();
        if (uri.getRawQuery() == null) return result;
        for (String field : uri.getRawQuery().split("&")) {
            String[] pair = field.split("=", 2);
            result.put(pair[0], pair.length == 2 ? pair[1] : "");
        }
        return result;
    }

    private static int integer(Map<String, String> query, String name) throws BadRequest {
        try { return Integer.parseInt(query.get(name)); }
        catch (RuntimeException exception) { throw new BadRequest("Missing or invalid " + name); }
    }

    private static String json(String value) {
        StringBuilder result = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '\\' -> result.append("\\\\");
                case '"' -> result.append("\\\"");
                case '\n' -> result.append("\\n");
                case '\r' -> result.append("\\r");
                case '\t' -> result.append("\\t");
                default -> {
                    if (c < 0x20) result.append(String.format("\\u%04x", (int) c));
                    else result.append(c);
                }
            }
        }
        return result.append('"').toString();
    }

    private static void respond(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = (body + "\n").getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.sendResponseHeaders(status, bytes.length);
        exchange.getResponseBody().write(bytes);
        exchange.close();
    }

    @FunctionalInterface
    private interface ThrowingHandler { void handle(HttpExchange exchange) throws Exception; }

    private static final class BadRequest extends Exception {
        BadRequest(String message) { super(message); }
    }
}
