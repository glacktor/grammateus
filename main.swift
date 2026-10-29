// Grammateus — локальный автопереключатель раскладки EN/RU.
// Никакой сети, ничего не пишет на диск, кроме настроек (UserDefaults).
// В полях паролей (secure input) не видит и не делает ничего.

import Cocoa
import Carbon
import ServiceManagement

// MARK: - Раскладки

struct Key: Equatable {
    let code: UInt16
    let shift: Bool
}

final class Source {
    let src: TISInputSource
    let id: String
    let lang: String      // "en" / "ru"
    let spellLang: String // язык для NSSpellChecker
    private let layoutData: CFData

    init?(_ src: TISInputSource) {
        guard let id: String = Source.prop(src, kTISPropertyInputSourceID),
              let langs: [String] = Source.prop(src, kTISPropertyInputSourceLanguages),
              let lang = langs.first.map({ String($0.prefix(2)) }), ["en", "ru"].contains(lang),
              let data: CFData = Source.prop(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        self.src = src
        self.id = id
        self.lang = lang
        self.layoutData = data
        let available = NSSpellChecker.shared.availableLanguages
        if lang == "en", id.contains("British"), available.contains("en_GB") {
            spellLang = "en_GB"
        } else {
            spellLang = lang
        }
    }

    static func prop<T>(_ s: TISInputSource, _ key: CFString) -> T? {
        guard let p = TISGetInputSourceProperty(s, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? T
    }

    func render(_ keys: [Key]) -> String {
        let ptr = CFDataGetBytePtr(layoutData)!
        return ptr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var out = ""
            for k in keys {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let mods: UInt32 = k.shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                UCKeyTranslate(layout, k.code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                out += String(utf16CodeUnits: chars, count: len)
            }
            return out
        }
    }

    func key(for ch: Character) -> Key? {
        for shift in [false, true] {
            for code: UInt16 in 0..<128 where render([Key(code: code, shift: shift)]) == String(ch) {
                return Key(code: code, shift: shift)
            }
        }
        return nil
    }
}

final class Layouts {
    private(set) var sources: [Source] = []

    init() { reload() }

    func reload() {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        sources = list.compactMap(Source.init)
    }

    func current() -> Source? {
        let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let id: String = Source.prop(cur, kTISPropertyInputSourceID) else { return nil }
        return sources.first { $0.id == id }
    }

    func other(than s: Source) -> Source? { sources.first { $0.lang != s.lang } }
    func source(lang: String) -> Source? { sources.first { $0.lang == lang } }
}

// MARK: - Настройки

final class Settings {
    private let d: UserDefaults

    static let defaultExcluded = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.jetbrains.", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4",
    ]

    init(_ d: UserDefaults = .standard) {
        self.d = d
        d.register(defaults: ["enabled": true, "doubleShift": true, "excluded": Settings.defaultExcluded, "ignored": []])
    }

    var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        set { d.set(newValue, forKey: "enabled") }
    }
    var doubleShift: Bool {
        get { d.bool(forKey: "doubleShift") }
        set { d.set(newValue, forKey: "doubleShift") }
    }
    var excluded: [String] {
        get { d.stringArray(forKey: "excluded") ?? [] }
        set { d.set(newValue, forKey: "excluded") }
    }
    var ignored: Set<String> {
        get { Set(d.stringArray(forKey: "ignored") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "ignored") }
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        // Запись с точкой на конце — префикс (например "com.jetbrains." — все IDE JetBrains).
        return excluded.contains { $0.hasSuffix(".") ? b.hasPrefix($0) : b == $0 }
    }
}

// MARK: - Логика

protocol Output: AnyObject {
    func backspace(_ n: Int)
    func type(_ s: String)
    func repost()                 // переотправить обрабатываемую сейчас клавишу
    func select(_ s: Source)
    func current() -> Source?
}

final class Engine {
    let layouts: Layouts
    let settings: Settings
    unowned let out: Output

    private var buf: [Key] = []
    private var prev: [Key]? = nil  // предыдущее слово, если после него был ровно один пробел
    private var undo: (original: String, deleteCount: Int, boundary: String, source: Source)? = nil

    static let oneLetter = ["ru": Set("авиксоуя".map(String.init)), "en": ["a", "i"]]
    static let twoLetter: [String: Set<String>] = [
        "ru": ["не", "на", "да", "по", "но", "за", "из", "то", "же", "ты", "он", "мы", "вы", "их", "её", "ее",
               "ни", "ли", "бы", "до", "от", "во", "со", "ко", "об", "ну", "уж", "ой", "ок", "её", "ей", "им"],
        "en": ["is", "it", "in", "on", "to", "of", "at", "be", "by", "do", "go", "he", "if", "me", "my", "no",
               "so", "up", "us", "we", "an", "as", "or", "am", "hi", "ok"],
    ]

    init(layouts: Layouts, settings: Settings, out: Output) {
        self.layouts = layouts
        self.settings = settings
        self.out = out
    }

    func reset() {
        buf = []
        prev = nil
        undo = nil
    }

    /// true — проглотить событие (мы сами его переотправим).
    func keyDown(code: UInt16, shift: Bool, otherMods: Bool) -> Bool {
        if otherMods { reset(); return false }
        switch code {
        case 51: return backspace()
        case 49, 36, 76, 48: return boundary(code)
        default: break
        }
        guard let cur = out.current() else { reset(); return false }
        let key = Key(code: code, shift: shift)
        let ch = cur.render([key])
        if ch.isEmpty || ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            reset() // стрелки, Esc, F-клавиши и т.п.
            return false
        }
        undo = nil
        buf.append(key)
        if buf.count > 50 { reset() }
        return false
    }

    private func backspace() -> Bool {
        if let u = undo {
            undo = nil
            out.backspace(u.deleteCount)
            out.type(u.original)
            out.select(u.source)
            remember(u.original)
            buf = []
            prev = nil
            return true
        }
        if buf.isEmpty { prev = nil } else { buf.removeLast() }
        return false
    }

    private func boundary(_ code: UInt16) -> Bool {
        undo = nil
        defer { buf = [] }
        guard !buf.isEmpty else { prev = nil; return false }
        let keys = buf
        guard settings.enabled, let cur = out.current(), let other = layouts.other(than: cur),
              let fix = decide(keys, cur, other) else {
            prev = code == 49 ? keys : nil
            return false
        }
        var original = cur.render(keys)
        var text = fix
        var del = original.count
        // «f rfr» → «а как»: однобуквенное слово перед исправленным тоже переводим.
        if let p = prev, p.count == 1 {
            let typedP = cur.render(p), altP = other.render(p)
            if Engine.oneLetter[other.lang]?.contains(altP.lowercased()) == true,
               Engine.oneLetter[cur.lang]?.contains(typedP.lowercased()) != true {
                del += 1 + typedP.count
                text = altP + " " + text
                original = typedP + " " + original
            }
        }
        out.backspace(del)
        out.type(text)
        out.repost()
        out.select(other)
        // Откат имеет смысл только после пробела/таба: Enter мог уже отправить сообщение.
        if code == 49 || code == 48 {
            undo = (original, text.count + 1, code == 49 ? " " : "\t", cur)
        }
        prev = code == 49 ? keys : nil
        return true
    }

    /// Двойной Shift: откатить исправление / перевести слово / просто переключить раскладку.
    func doubleShift() {
        guard let cur = out.current(), let other = layouts.other(than: cur) else { return }
        if let u = undo {
            undo = nil
            out.backspace(u.deleteCount)
            out.type(u.original + u.boundary)
            out.select(u.source)
            remember(u.original)
            buf = []
            prev = nil
        } else if !buf.isEmpty {
            out.backspace(cur.render(buf).count)
            out.type(other.render(buf))
            out.select(other)
        } else if let p = prev {
            out.backspace(cur.render(p).count + 1)
            out.type(other.render(p) + " ")
            out.select(other)
        } else {
            out.select(other)
        }
    }

    // MARK: решение

    func decide(_ keys: [Key], _ cur: Source, _ other: Source) -> String? {
        let typed = cur.render(keys), alt = other.render(keys)
        guard typed.count == keys.count, alt.count == keys.count else { return nil }
        if settings.ignored.contains(typed.lowercased()) { return nil }

        // Слово целиком: «ghbdtn» → «привет», «руддщб» → «hello,».
        let altCore = Engine.core(alt)
        if altCore.count >= 2, validAlt(altCore, other), !validTyped(Engine.core(typed), cur) {
            return alt
        }
        // Знаки по краям оставляем как набраны: «ghbdtn,» → «привет,».
        let chars = Array(typed)
        let lead = chars.prefix { !$0.isLetter }.count
        let trail = chars.reversed().prefix { !$0.isLetter }.count
        if lead + trail > 0, lead + trail < keys.count {
            let mid = Array(keys[lead..<(keys.count - trail)])
            let altMid = other.render(mid), typedMid = cur.render(mid)
            if altMid.count >= 2, altMid.allSatisfy(\.isLetter), validAlt(altMid, other), !validTyped(typedMid, cur) {
                return String(chars[..<lead]) + altMid + String(chars[(keys.count - trail)...])
            }
        }
        return nil
    }

    static func core(_ s: String) -> String {
        let a = Array(s)
        guard let first = a.firstIndex(where: \.isLetter), let last = a.lastIndex(where: \.isLetter) else { return "" }
        return String(a[first...last])
    }

    private static func inScript(_ w: String, _ lang: String) -> Bool {
        w.unicodeScalars.allSatisfy { u in
            if u == "-" || u == "'" || u == "’" { return true }
            if lang == "ru" { return (0x0400...0x04FF).contains(u.value) }
            return u.isASCII && CharacterSet.letters.contains(u)
        }
    }

    private static func spellOK(_ w: String, _ lang: String) -> Bool {
        // Слова КАПСОМ словарь считает аббревиатурами и пропускает — проверяем строчными.
        let w = w.count > 2 && w == w.uppercased() ? w.lowercased() : w
        return NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// Набранное слово считаем нормальным мягко: всё, что знает словарь.
    private func validTyped(_ w: String, _ s: Source) -> Bool {
        !w.isEmpty && Engine.inScript(w, s.lang) && Engine.spellOK(w, s.spellLang)
    }

    /// Замену требуем строго: короткие слова — только из белого списка.
    private func validAlt(_ w: String, _ s: Source) -> Bool {
        guard !w.isEmpty, Engine.inScript(w, s.lang) else { return false }
        if w.count <= 2 { return Engine.twoLetter[s.lang]?.contains(w.lowercased()) == true }
        return Engine.spellOK(w, s.spellLang)
    }

    private func remember(_ original: String) {
        var ig = settings.ignored
        for w in original.split(separator: " ") where w.count > 1 { ig.insert(w.lowercased()) }
        settings.ignored = ig
    }
}

// MARK: - Перехват клавиатуры

let magic: Int64 = 0x4C61_7946 // помечаем свои события, чтобы не ловить их повторно

final class Tap: Output {
    let layouts = Layouts()
    let settings = Settings()
    lazy var engine = Engine(layouts: layouts, settings: settings, out: self)
    private var tap: CFMachPort?
    private var currentEvent: CGEvent?
    private let src = CGEventSource(stateID: .privateState)
    var excludedNow = false
    var onLayoutChange: (() -> Void)?

    // Двойной Shift
    private var shiftDown = false
    private var shiftClean = false
    private var lastShiftTap: TimeInterval = 0

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            let me = Unmanaged<Tap>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == magic { return Unmanaged.passUnretained(event) }
        if excludedNow || IsSecureEventInputEnabled() {
            engine.reset()
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .keyDown:
            shiftClean = false
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 && event.getIntegerValueField(.keyboardEventKeycode) != 51 {
                engine.reset()
                return Unmanaged.passUnretained(event)
            }
            let f = event.flags
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            currentEvent = event
            defer { currentEvent = nil }
            let swallow = engine.keyDown(code: code,
                                         shift: f.contains(.maskShift) || f.contains(.maskAlphaShift),
                                         otherMods: !f.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]))
            return swallow ? nil : Unmanaged.passUnretained(event)
        case .flagsChanged:
            handleShift(event.flags)
        default:
            engine.reset() // клик мышью — курсор мог переехать
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleShift(_ f: CGEventFlags) {
        let isShift = f.contains(.maskShift)
        let others = !f.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate])
        if isShift && !shiftDown {
            shiftDown = true
            shiftClean = !others
        } else if !isShift && shiftDown {
            shiftDown = false
            guard shiftClean, settings.doubleShift else { lastShiftTap = 0; return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShiftTap < 0.4 {
                lastShiftTap = 0
                engine.doubleShift()
            } else {
                lastShiftTap = now
            }
        } else if others {
            shiftClean = false
        }
    }

    // MARK: Output

    private func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: magic)
        e.post(tap: .cgSessionEventTap)
    }

    func backspace(_ n: Int) {
        for _ in 0..<n {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down) else { continue }
                e.flags = []
                post(e)
            }
        }
    }

    func type(_ s: String) {
        for ch in s {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                post(e)
            }
        }
    }

    func repost() {
        if let e = currentEvent?.copy() { post(e) }
    }

    func select(_ s: Source) {
        TISSelectInputSource(s.src)
        onLayoutChange?()
    }

    func current() -> Source? { layouts.current() }
}

// MARK: - Меню-бар

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let tap = Tap()
    var item: NSStatusItem!
    var retry: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        tap.onLayoutChange = { [weak self] in DispatchQueue.main.async { self?.refresh() } }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.tap.layouts.reload(); self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.appChanged() }

        appChanged()
        startTap(prompt: true)
    }

    func startTap(prompt: Bool) {
        if prompt {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            _ = CGRequestListenEventAccess()
        }
        if tap.start() {
            retry?.invalidate()
            retry = nil
        } else if retry == nil {
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.startTap(prompt: false)
                self?.refresh()
            }
        }
        refresh()
    }

    var hasAccess: Bool { retry == nil }

    func appChanged() {
        tap.excludedNow = tap.settings.isExcluded(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        tap.engine.reset()
        refresh()
    }

    func refresh() {
        guard let button = item.button else { return }
        let lang = tap.layouts.current()?.lang.uppercased() ?? "??"
        button.title = hasAccess ? lang : "⚠︎ \(lang)"
        button.appearsDisabled = !tap.settings.enabled || tap.excludedNow
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = tap.settings
        if !hasAccess {
            add(menu, "⚠︎ Нужен доступ: Универсальный доступ + Мониторинг ввода…", #selector(openPrivacy))
            menu.addItem(.separator())
        }
        add(menu, "Автоисправление", #selector(toggleEnabled), on: s.enabled)
        add(menu, "Двойной Shift — исправить слово / сменить язык", #selector(toggleShift), on: s.doubleShift)
        menu.addItem(.separator())

        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier {
            let name = app.localizedName ?? id
            add(menu, "Не исправлять в «\(name)»", #selector(toggleFrontmost), on: s.isExcluded(id))
        }
        let ex = NSMenuItem(title: "Исключения", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for id in s.excluded {
            let mi = NSMenuItem(title: id, action: #selector(removeExcluded(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
            mi.toolTip = "Нажми, чтобы убрать из исключений"
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        add(sub, "Вернуть список по умолчанию", #selector(resetExcluded))
        ex.submenu = sub
        menu.addItem(ex)

        let ignored = s.ignored.count
        add(menu, "Забыть отменённые слова (\(ignored))", #selector(clearIgnored)).isEnabled = ignored > 0
        menu.addItem(.separator())
        add(menu, "Запускать при входе", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add(menu, "Выход", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        if let on { mi.state = on ? .on : .off }
        menu.addItem(mi)
        return mi
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func toggleEnabled() { tap.settings.enabled.toggle(); tap.engine.reset(); refresh() }
    @objc func toggleShift() { tap.settings.doubleShift.toggle() }
    @objc func toggleFrontmost() {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        var ex = tap.settings.excluded
        if tap.settings.isExcluded(id) {
            ex.removeAll { $0 == id || ($0.hasSuffix(".") && id.hasPrefix($0)) }
        } else {
            ex.append(id)
        }
        tap.settings.excluded = ex
        appChanged()
    }
    @objc func removeExcluded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        tap.settings.excluded.removeAll { $0 == id }
        appChanged()
    }
    @objc func resetExcluded() { tap.settings.excluded = Settings.defaultExcluded; appChanged() }
    @objc func clearIgnored() { tap.settings.ignored = [] }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Не получилось изменить автозапуск"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Самопроверка (без доступа к клавиатуре)

final class FakeOutput: Output {
    var text = ""
    var cur: Source
    var pendingBoundary = ""
    init(_ cur: Source) { self.cur = cur }
    func backspace(_ n: Int) { text.removeLast(min(n, text.count)) }
    func type(_ s: String) { text += s }
    func repost() { text += pendingBoundary }
    func select(_ s: Source) { cur = s }
    func current() -> Source? { cur }
}

func selfTest() -> Int32 {
    let layouts = Layouts()
    let settings = Settings(UserDefaults(suiteName: "grammateus.selftest")!)
    // «⇧⇧» — двойной Shift, «⌫» — Backspace. Клавиши берутся по стартовой раскладке.
    let cases: [(String, String, String)] = [
        ("en", "ghbdtn ", "привет "),
        ("ru", "руддщ ", "hello "),
        ("en", "f rfr ltkf ", "а как дела "),
        ("en", "ghbdtn, rfr ltkf ", "привет, как дела "),
        ("en", "yt pyf. ", "не знаю "),
        ("ru", "щл ", "ok "),
        ("ru", "ш ерштл ", "i think "),
        ("en", "GHBDTN ", "ПРИВЕТ "),
        ("en", "ghbdtn ⌫", "ghbdtn"),
        ("en", "ghbdtn ⇧⇧", "ghbdtn "),
        ("en", "zyltrc⇧⇧ ", "яндекс "),
        ("en", "hello world ", "hello world "),
        ("ru", "привет мир как дела ", "привет мир как дела "),
        ("en", "git commit vs npm cd ls api json url ssh todo lol btw ok ", "git commit vs npm cd ls api json url ssh todo lol btw ok "),
        ("en", "a b c i x ", "a b c i x "),
        ("ru", "я в и с к у ", "я в и с к у "),
    ]
    var failed = 0
    for (lang, input, expected) in cases {
        settings.ignored = []
        guard let start = layouts.source(lang: lang) else { print("нет раскладки \(lang)"); return 1 }
        let out = FakeOutput(start)
        let engine = Engine(layouts: layouts, settings: settings, out: out)
        var shifts = 0
        for ch in input {
            if ch == "⇧" {
                shifts += 1
                if shifts == 2 { engine.doubleShift(); shifts = 0 }
                continue
            }
            shifts = 0
            switch ch {
            case "⌫":
                out.pendingBoundary = ""
                if !engine.keyDown(code: 51, shift: false, otherMods: false), !out.text.isEmpty { out.text.removeLast() }
            case " ":
                out.pendingBoundary = " "
                if !engine.keyDown(code: 49, shift: false, otherMods: false) { out.text += " " }
            default:
                guard let k = start.key(for: ch) else { print("нет клавиши для \(ch)"); return 1 }
                if !engine.keyDown(code: k.code, shift: k.shift, otherMods: false) { out.text += out.cur.render([k]) }
            }
        }
        let ok = out.text == expected
        if !ok { failed += 1 }
        print(ok ? "OK  " : "FAIL", "[\(lang)] \(input.debugDescription) → \(out.text.debugDescription)", ok ? "" : "(ждали \(expected.debugDescription))")
    }
    print(failed == 0 ? "Все тесты прошли" : "Провалено: \(failed)")
    return failed == 0 ? 0 : 1
}

// MARK: - Запуск

if CommandLine.arguments.contains("--selftest") {
    exit(selfTest())
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
