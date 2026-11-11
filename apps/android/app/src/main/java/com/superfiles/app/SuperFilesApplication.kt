package com.superfiles.app

import android.app.Application

class SuperFilesApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // 任何入口（Activity / Service / Provider 冷启动）都先初始化文案资源。
        L10n.init(this)
    }
}
