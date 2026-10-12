package com.jai.assistant;

import android.content.Context;
import android.content.SharedPreferences;

/** Хранение адреса сервера между запусками приложения. */
public class ServerConfig {

    private static final String PREFS = "jai_prefs";
    private static final String KEY_SERVER = "server_url";

    public static String getServer(Context ctx, String fallback) {
        SharedPreferences p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        return p.getString(KEY_SERVER, fallback);
    }

    public static void setServer(Context ctx, String url) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY_SERVER, url).apply();
    }
}
