/*
 * kio_superfiles — the `superfiles://` KIO worker for KDE (Dolphin/Konqueror).
 *
 * The protocol is a thin shell over the Super Files kernel CLI:
 * every URL maps to a kernel id (`superfiles:///label/rest` -> mount labeled
 * `label`, joined onto its root id), and all real work happens in
 * `sfiles kio ls/stat/cat` (see crates/sfiles-cli/src/kio.rs).
 *
 *   superfiles:///                 virtual root: one folder per mount
 *   superfiles:///123pan/docs      -> webdav://…/docs on the "123pan" mount
 *   superfiles:///Home/super-files -> a local jailed path
 *
 * Read-only for now (browsing + open/copy/preview); write operations arrive
 * with the same plumbing later.
 */

#include <KIO/WorkerBase>
#include <KIO/WorkerFactory>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QProcessEnvironment>
#include <QUrl>
#include <QTimer>
#include <memory>

#include <kdirnotify.h> // KDirNotify: to invalidate the root when mounts change

using namespace KIO;

static QString sfilesBin()
{
    QString exe = qEnvironmentVariable("SFILES_BIN");
    if (exe.isEmpty())
        exe = QStringLiteral("sfiles");
    return exe;
}

// Forward SF_MOUNTS_CONFIG-less kernel overrides to the child verbatim.
static QProcessEnvironment childEnv()
{
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    Q_UNUSED(env);
    return env;
}

class SuperfilesWorker : public KIO::WorkerBase
{
public:
    SuperfilesWorker(const QByteArray &pool, const QByteArray &app)
        : WorkerBase(QByteArrayLiteral("superfiles"), pool, app)
    {
    }

    struct Mount {
        QString label;
        QString rootId;
        QString kind;
    };

    QList<Mount> m_mounts;
    bool m_mountsLoaded = false;

    // ---- helpers -------------------------------------------------------

    bool loadMounts(QString *error)
    {
        QProcess proc;
        proc.start(sfilesBin(), {QStringLiteral("kio"), QStringLiteral("mounts")});
        if (!proc.waitForStarted(5000)) {
            *error = QStringLiteral("cannot start %1").arg(sfilesBin());
            return false;
        }
        if (!proc.waitForFinished(60000)) {
            proc.kill();
            *error = QStringLiteral("sfiles kio mounts timed out");
            return false;
        }
        const QByteArray err = proc.readAllStandardError();
        if (proc.exitCode() != 0) {
            *error = errTrim(err);
            return false;
        }
        m_mounts.clear();
        for (const QByteArray &line : proc.readAllStandardOutput().split('\n')) {
            if (line.trimmed().isEmpty())
                continue;
            const QJsonDocument doc = QJsonDocument::fromJson(line);
            const QJsonObject obj = doc.object();
            Mount m;
            m.label = obj.value(QStringLiteral("label")).toString();
            m.rootId = obj.value(QStringLiteral("root_id")).toString();
            m.kind = obj.value(QStringLiteral("kind")).toString();
            if (!m.label.isEmpty() && !m.rootId.isEmpty())
                m_mounts.append(m);
        }
        m_mountsLoaded = !m_mounts.isEmpty();
        if (!m_mountsLoaded) {
            *error = QStringLiteral("no storages configured (~/.config/superfiles/mounts.json)");
            return false;
        }
        return true;
    }

    static QString errTrim(const QByteArray &stderrBytes)
    {
        QString msg = QString::fromUtf8(stderrBytes).trimmed();
        // e.g. "error: not found" -> "not found"; keep whatever the kernel said.
        if (msg.startsWith(QLatin1String("error: ")))
            msg = msg.mid(7);
        return msg.split('\n').first();
    }

    struct Resolved {
        // isRoot: the virtual mount list; id empty.
        bool isRoot = false;
        QString id;  // kernel id, empty for root
    };

    bool resolve(const QUrl &url, Resolved *out, QString *error)
    {
        if (!m_mountsLoaded && !loadMounts(error))
            return false;

        // url.path() is percent-decoded ("A B" stays "A B").
        QString path = url.path(QUrl::FullyDecoded);
        // KIO insists a URL path starts with '/', strip it.
        while (path.startsWith(QLatin1Char('/')))
            path.remove(0, 1);
        if (path.isEmpty()) {
            out->isRoot = true;
            out->id.clear();
            return true;
        }

        const int slash = path.indexOf(QLatin1Char('/'));
        const QString label = slash < 0 ? path : path.left(slash);
        QString rest = slash < 0 ? QString() : path.mid(slash + 1);
        while (rest.endsWith(QLatin1Char('/')))
            rest.chop(1);

        for (const Mount &m : std::as_const(m_mounts)) {
            if (m.label != label)
                continue;
            if (rest.isEmpty()) {
                out->id = m.rootId;
            } else {
                out->id = m.rootId.endsWith(QLatin1Char('/'))
                    ? m.rootId + rest
                    : m.rootId + QLatin1Char('/') + rest;
            }
            return true;
        }
        *error = QStringLiteral("no storage labeled '%1'").arg(label);
        return false;
    }

    // Run `sfiles kio …` and hand back each stdout line as one JSON object.
    // Returns false + fills `error` on non-zero exit (kernel message wins).
    static bool runJson(const QStringList &args, QList<QJsonObject> *out, QString *error, int timeoutMs = 60000)
    {
        QProcess proc;
        proc.start(sfilesBin(), args);
        if (!proc.waitForStarted(5000)) {
            *error = QStringLiteral("cannot start %1").arg(sfilesBin());
            return false;
        }
        if (!proc.waitForFinished(timeoutMs)) {
            proc.kill();
            *error = QStringLiteral("%1 timed out").arg(args.join(' '));
            return false;
        }
        const QByteArray err = proc.readAllStandardError();
        if (proc.exitStatus() != QProcess::NormalExit || proc.exitCode() != 0) {
            *error = err.isEmpty() ? QStringLiteral("kernel error (exit %1)").arg(proc.exitCode()) : errTrim(err);
            return false;
        }
        for (const QByteArray &line : proc.readAllStandardOutput().split('\n')) {
            if (line.trimmed().isEmpty())
                continue;
            const QJsonDocument doc = QJsonDocument::fromJson(line);
            if (doc.isObject())
                out->append(doc.object());
        }
        return true;
    }

    static UDSEntry entryFromJson(const QJsonObject &obj)
    {
        UDSEntry entry;
        const QString kind = obj.value(QStringLiteral("kind")).toString();

        entry.reserve(7);
        entry.fastInsert(UDSEntry::UDS_NAME, obj.value(QStringLiteral("name")).toString());
        if (kind == QLatin1String("dir"))
            entry.fastInsert(UDSEntry::UDS_FILE_TYPE, S_IFDIR);
        else if (kind == QLatin1String("symlink"))
            entry.fastInsert(UDSEntry::UDS_FILE_TYPE, S_IFLNK);
        else
            entry.fastInsert(UDSEntry::UDS_FILE_TYPE, S_IFREG);
        entry.fastInsert(UDSEntry::UDS_SIZE, (KIO::filesize_t)obj.value(QStringLiteral("size")).toDouble());
        if (obj.contains(QStringLiteral("modified_ms"))) {
            const double ms = obj.value(QStringLiteral("modified_ms")).toDouble();
            entry.fastInsert(UDSEntry::UDS_MODIFICATION_TIME, (time_t)(ms / 1000.0));
        }
        const QString mime = obj.value(QStringLiteral("mime")).toString();
        if (!mime.isEmpty()) {
            entry.fastInsert(UDSEntry::UDS_MIME_TYPE, mime);
            entry.fastInsert(UDSEntry::UDS_ICON_NAME, mime);
        }
        entry.fastInsert(UDSEntry::UDS_HIDDEN, obj.value(QStringLiteral("hidden")).toBool());
        entry.fastInsert(UDSEntry::UDS_ACCESS, obj.value(QStringLiteral("readonly")).toBool() ? 0444 : 0644);
        return entry;
    }

    static UDSEntry mountEntry(const Mount &m)
    {
        UDSEntry entry;
        entry.reserve(4);
        entry.fastInsert(UDSEntry::UDS_NAME, m.label);
        entry.fastInsert(UDSEntry::UDS_FILE_TYPE, S_IFDIR);
        entry.fastInsert(UDSEntry::UDS_ACCESS, 0555);
        entry.fastInsert(
            UDSEntry::UDS_ICON_NAME,
            m.kind == QLatin1String("webdav") ? QStringLiteral("folder-remote")
                                             : m.kind == QLatin1String("local") ? QStringLiteral("user-home")
                                                                                : QStringLiteral("network-server"));
        return entry;
    }

    // ---- KIO ------------------------------------------------------------

    WorkerResult stat(const QUrl &url) override
    {
        QString error;
        Resolved target;
        if (!resolve(url, &target, &error))
            return WorkerResult::fail(ERR_WORKER_DEFINED, error);

        if (target.isRoot) {
            UDSEntry entry;
            entry.reserve(3);
            entry.fastInsert(UDSEntry::UDS_NAME, QStringLiteral("/"));
            entry.fastInsert(UDSEntry::UDS_FILE_TYPE, S_IFDIR);
            entry.fastInsert(UDSEntry::UDS_ACCESS, 0555);
            statEntry(entry);
            return WorkerResult::pass();
        }

        QList<QJsonObject> rows;
        if (!runJson({QStringLiteral("kio"), QStringLiteral("stat"), target.id}, &rows, &error))
            return WorkerResult::fail(ERR_WORKER_DEFINED, error);
        if (rows.isEmpty())
            return WorkerResult::fail(ERR_DOES_NOT_EXIST, target.id);
        statEntry(entryFromJson(rows.first()));
        return WorkerResult::pass();
    }

    WorkerResult listDir(const QUrl &url) override
    {
        QString error;
        Resolved target;
        if (!resolve(url, &target, &error))
            return WorkerResult::fail(ERR_WORKER_DEFINED, error);

        if (target.isRoot) {
            // Re-resolve on every root listing so config edits show up immediately.
            m_mountsLoaded = false;
            if (!loadMounts(&error))
                return WorkerResult::fail(ERR_WORKER_DEFINED, error);
            UDSEntryList list;
            for (const Mount &m : std::as_const(m_mounts))
                list.append(mountEntry(m));
            listEntries(list);
            return WorkerResult::pass();
        }

        QList<QJsonObject> rows;
        if (!runJson({QStringLiteral("kio"), QStringLiteral("ls"), target.id}, &rows, &error))
            return WorkerResult::fail(ERR_WORKER_DEFINED, error);

        UDSEntryList list;
        for (const QJsonObject &obj : std::as_const(rows))
            list.append(entryFromJson(obj));
        listEntries(list);
        return WorkerResult::pass();
    }

    WorkerResult mimetype(const QUrl &url) override
    {
        QString error;
        Resolved target;
        if (!resolve(url, &target, &error))
            return WorkerResult::fail(ERR_WORKER_DEFINED, error);
        if (target.isRoot)
            return WorkerResult::pass(); // stat/root has no mimetype to add

        QList<QJsonObject> rows;
        if (!runJson({QStringLiteral("kio"), QStringLiteral("stat"), target.id}, &rows, &error))
            return WorkerResult::fail(ERR_WORKER_DEFINED, error);
        const QString mime = rows.isEmpty() ? QString()
            : rows.first().value(QStringLiteral("mime")).toString();
        if (!mime.isEmpty())
            mimeType(mime);
        return WorkerResult::pass();
    }

    WorkerResult get(const QUrl &url) override
    {
        QString error;
        Resolved target;
        if (!resolve(url, &target, &error))
            return WorkerResult::fail(ERR_WORKER_DEFINED, error);
        if (target.isRoot)
            return WorkerResult::fail(ERR_IS_DIRECTORY, target.id);

        // size + mime up front, when cheap; stat errors on a plain open are fine
        // to ignore (some backends only discover details while streaming).
        QList<QJsonObject> rows;
        const bool haveStat = runJson({QStringLiteral("kio"), QStringLiteral("stat"), target.id}, &rows, &error, 30000);
        if (haveStat && !rows.isEmpty()) {
            totalSize((KIO::filesize_t)rows.first().value(QStringLiteral("size")).toDouble());
            const QString mime = rows.first().value(QStringLiteral("mime")).toString();
            if (!mime.isEmpty())
                mimeType(mime);
        }

        QProcess proc;
        proc.start(sfilesBin(), {QStringLiteral("kio"), QStringLiteral("cat"), target.id});
        if (!proc.waitForStarted(5000))
            return WorkerResult::fail(ERR_WORKER_DEFINED, QStringLiteral("cannot start %1").arg(sfilesBin()));

        while (true) {
            if (!proc.waitForReadyRead(300000)) {
                if (proc.state() == QProcess::NotRunning)
                    break;
                continue; // long stall on slow NAS links, keep waiting until EOF
            }
            const QByteArray chunk = proc.readAllStandardOutput();
            if (!chunk.isEmpty())
                data(chunk);
        }
        // Drain whatever is left in the pipe after the process exits.
        const QByteArray tail = proc.readAllStandardOutput();
        if (!tail.isEmpty())
            data(tail);

        data(QByteArray()); // EOF
        if (proc.exitStatus() != QProcess::NormalExit || proc.exitCode() != 0) {
            const QString kernelMessage = errTrim(proc.readAllStandardError());
            return WorkerResult::fail(ERR_WORKER_DEFINED,
                kernelMessage.isEmpty() ? QStringLiteral("transfer interrupted") : kernelMessage);
        }
        return WorkerResult::pass();
    }
};

// KIO workers register through their own factory (not KPluginFactory):
// the IID follows the "org.kde.kio.worker.<protocol>" convention, the JSON
// carries both the plugin metadata and the KDE-KIO-Protocols entry KIO uses
// to discover `superfiles://`.
class SuperfilesWorkerFactory : public KIO::WorkerFactory
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID "org.kde.kio.worker.superfiles" FILE "superfiles.json")

public:
    std::unique_ptr<KIO::WorkerBase> createWorker(const QByteArray &pool, const QByteArray &app) override
    {
        return std::make_unique<SuperfilesWorker>(pool, app);
    }
};

#include "kio_superfiles.moc"
