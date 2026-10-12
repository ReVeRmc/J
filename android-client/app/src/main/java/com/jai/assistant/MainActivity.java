package com.jai.assistant;

import android.Manifest;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.speech.tts.TextToSpeech;
import android.view.View;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * J AI Assistant — минималистичный клиент.
 * Строка чата + одна большая голосовая кнопка по центру экрана.
 */
public class MainActivity extends AppCompatActivity {

    private static final String DEFAULT_SERVER = "http://192.168.0.100:8080";
    private static final int REQ_MIC = 100;

    private EditText inputMessage;
    private TextView chatLog;
    private ScrollView scrollChat;
    private ImageButton micButton;

    private SpeechRecognizer speechRecognizer;
    private TextToSpeech tts;
    private boolean ttsReady = false;
    private boolean listening = false;
    private boolean voiceOutputEnabled = true;
    private ExecutorService executor;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        inputMessage = findViewById(R.id.input_message);
        chatLog = findViewById(R.id.chat_log);
        scrollChat = findViewById(R.id.scroll_chat);
        micButton = findViewById(R.id.mic_button);
        EditText serverInput = findViewById(R.id.input_server);
        serverInput.setText(ServerConfig.getServer(this, DEFAULT_SERVER));

        executor = Executors.newSingleThreadExecutor();

        // Разрешение на микрофон
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this,
                    new String[]{Manifest.permission.RECORD_AUDIO}, REQ_MIC);
        }

        initTts();
        initSpeechRecognizer();

        // Отправка текстом
        findViewById(R.id.btn_send).setOnClickListener(v -> {
            String text = inputMessage.getText().toString().trim();
            if (!text.isEmpty()) {
                inputMessage.setText("");
                sendToServer(text);
            }
        });

        // Большая голосовая кнопка по центру: клик — слушать, долгое нажатие — вкл/выкл озвучку
        micButton.setOnClickListener(v -> toggleVoice());
        micButton.setOnLongClickListener(v -> {
            voiceOutputEnabled = !voiceOutputEnabled;
            toast(voiceOutputEnabled ? "Озвучивание ответов включено" : "Озвучивание ответов выключено");
            return true;
        });

        findViewById(R.id.btn_save_server).setOnClickListener(v -> {
            String url = serverInput.getText().toString().trim();
            if (url.startsWith("http")) {
                ServerConfig.setServer(this, url);
                appendLog("system", "Сервер сохранен: " + url);
            } else {
                toast("Адрес должен начинаться с http://");
            }
        });

        appendLog("assistant", "J AI Assistant готов. Нажмите кнопку или введите команду.\n" +
                "Примеры: «помощь», «выполни ipconfig», «покажи файл C:\\notes.txt»");
    }

    // ================= ГОЛОС =================

    private void toggleVoice() {
        if (listening) {
            stopListeningUI();
            if (speechRecognizer != null) speechRecognizer.cancel();
            return;
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this,
                    new String[]{Manifest.permission.RECORD_AUDIO}, REQ_MIC);
            return;
        }
        if (speechRecognizer == null || !SpeechRecognizer.isRecognitionAvailable(this)) {
            toast("Голосовое распознавание недоступно");
            return;
        }
        startListeningUI(true);
        android.content.Intent intent = new android.content.Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault());
        intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        try {
            speechRecognizer.startListening(intent);
        } catch (Exception e) {
            startListeningUI(false);
            toast("Ошибка запуска распознавания");
        }
    }

    private void initSpeechRecognizer() {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) return;
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this);
        speechRecognizer.setRecognitionListener(new RecognitionListener() {
            @Override public void onReadyForSpeech(Bundle params) { }
            @Override public void onBeginningOfSpeech() { }
            @Override public void onRmsChanged(float rmsdB) { }
            @Override public void onBufferReceived(byte[] buffer) { }
            @Override public void onEndOfSpeech() { }

            @Override
            public void onError(int error) {
                runOnUiThread(() -> {
                    startListeningUI(false);
                    if (error != SpeechRecognizer.ERROR_CLIENT && error != SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                        toast("Словарь не распознан, повторите");
                    }
                });
            }

            @Override
            public void onResults(Bundle results) {
                ArrayList<String> list = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                runOnUiThread(() -> {
                    startListeningUI(false);
                    if (list != null && !list.isEmpty()) {
                        String spoken = list.get(0);
                        appendLog("user", spoken + "  🎤");
                        sendToServer(spoken);
                    }
                });
            }

            @Override public void onPartialResults(Bundle partialResults) { }
            @Override public void onEvent(int eventType, Bundle params) { }
        });
    }

    private void startListeningUI(boolean on) {
        listening = on;
        micButton.setBackgroundResource(on ? R.drawable.bg_mic_active : R.drawable.bg_mic);
        findViewById(R.id.status_listening).setVisibility(on ? View.VISIBLE : View.GONE);
    }

    private void stopListeningUI() { startListeningUI(false); }

    // ================= СЕРВЕР =================

    private void sendToServer(String message) {
        appendLog("user", message);
        executor.execute(() -> {
            String reply;
            try {
                reply = postToServer(message);
            } catch (Exception e) {
                reply = "⚠ Сервер недоступен: " + e.getMessage() +
                        "\nПроверьте адрес сервера и что сервер запущен.";
            }
            final String answer = reply;
            runOnUiThread(() -> {
                appendLog("assistant", answer);
                if (voiceOutputEnabled) speak(answer);
            });
        });
    }

    private String postToServer(String message) throws Exception {
        String base = ServerConfig.getServer(this, DEFAULT_SERVER);
        URL url = new URL(base + "/");
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
        conn.setConnectTimeout(8000);
        conn.setReadTimeout(60000);
        conn.setDoOutput(true);
        conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");

        JSONObject body = new JSONObject();
        body.put("message", message);
        byte[] out = body.toString().getBytes(StandardCharsets.UTF_8);
        conn.getOutputStream().write(out);

        int code = conn.getResponseCode();
        BufferedReader reader = new BufferedReader(new InputStreamReader(
                code >= 400 ? conn.getErrorStream() : conn.getInputStream(), StandardCharsets.UTF_8));
        StringBuilder sb = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) sb.append(line);
        reader.close();
        conn.disconnect();

        JSONObject json = new JSONObject(sb.toString());
        if (json.has("response")) return json.getString("response");
        if (json.has("error")) return "⚠ Ошибка сервера: " + json.getString("error");
        return sb.toString();
    }

    // ================= TTS =================

    private void initTts() {
        tts = new TextToSpeech(this, status -> {
            if (status == TextToSpeech.SUCCESS) {
                int r = tts.setLanguage(Locale.getDefault());
                ttsReady = r != TextToSpeech.LANG_MISSING_DATA && r != TextToSpeech.LANG_NOT_SUPPORTED;
            }
        });
    }

    private void speak(String text) {
        if (!ttsReady || text == null) return;
        String clean = text.replaceAll("[\\p{Punct}&&[^.,!?]]", "").replaceAll("\\s+", " ");
        if (clean.length() > 700) clean = clean.substring(0, 700);
        tts.speak(clean, TextToSpeech.QUEUE_FLUSH, null, "reply");
    }

    // ================= ЛОГ =================

    private void appendLog(String role, String text) {
        runOnUiThread(() -> {
            String prefix = role.equals("user") ? "🟢 Вы: " : (role.equals("assistant") ? "🤖 " : "ℹ️ ");
            chatLog.append(prefix + text + "\n\n");
            scrollChat.post(() -> scrollChat.fullScroll(View.FOCUS_DOWN));
        });
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_SHORT).show();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == REQ_MIC && results.length > 0
                && results[0] != PackageManager.PERMISSION_GRANTED) {
            toast("Без микрофона голосовой диалог недоступен (текст работает)");
        }
    }

    @Override
    protected void onDestroy() {
        if (speechRecognizer != null) { speechRecognizer.destroy(); speechRecognizer = null; }
        if (tts != null) { tts.shutdown(); }
        executor.shutdownNow();
        super.onDestroy();
    }
}
