// SPDX-FileCopyrightText: 2019 Contributors to Chatterino <https://chatterino.com>
//
// SPDX-License-Identifier: MIT

#pragma once

#include "debug/AssertInGuiThread.hpp"

#include <QCoreApplication>
#include <QMetaObject>

namespace chatterino {

/// @brief Invokes @a f on @a obj's thread
///
/// This does *not* defer work. The default Qt::AutoConnection resolves to a
/// direct call when @a f is invoked from @a obj's own thread, so on the GUI
/// thread this runs immediately. Use it to reach @a obj's thread, not to run
/// something later - pass Qt::QueuedConnection explicitly for that.
static void postToThread(auto &&f, QObject *obj = QCoreApplication::instance())
{
    QMetaObject::invokeMethod(obj, std::forward<decltype(f)>(f));
}

static void runInGuiThread(auto &&fun)
{
    if (isGuiThread())
    {
        fun();
    }
    else
    {
        postToThread(std::forward<decltype(fun)>(fun));
    }
}

inline void postToGuiThread(auto &&fun)
{
    assert(!isGuiThread() &&
           "postToGuiThread must be called from a non-GUI thread");

    postToThread(std::forward<decltype(fun)>(fun));
}

}  // namespace chatterino
