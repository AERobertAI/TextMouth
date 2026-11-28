import Foundation

enum UTF8Arrays {
    static let whitespace = " ".utf8Array
    static let newline = "\n".utf8Array
    static let bang = "!".utf8Array
    static let equalSign = "=".utf8Array
    static let ampersand = "&".utf8Array
    static let hyphen = "-".utf8Array
    static let doubleHyphen = "--".utf8Array
    static let doubleHyphenBang = "--!".utf8Array
    static let underscore = "_".utf8Array
    static let semicolon = ";".utf8Array
    static let questionMark = "?".utf8Array
    static let forwardSlash = "/".utf8Array
    static let selfClosingTagEnd = " />".utf8Array
    static let endTagStart = "</".utf8Array
    static let tagStart = "<".utf8Array
    static let tagStartBang = "<!".utf8Array
    static let tagEnd = ">".utf8Array
    static let attributeEqualsQuoteMark = "=\"".utf8Array
    static let quoteMark = "\"".utf8Array
    public static let html = "html".utf8Array
    static let head = "head".utf8Array
    static let meta = "meta".utf8Array
    public static let body = "body".utf8Array
    static let cite = "cite".utf8Array
    static let a = "a".utf8Array
    static let p = "p".utf8Array
    static let div = "div".utf8Array
    static let li = "li".utf8Array
    static let span = "span".utf8Array
    static let img = "img".utf8Array
    static let dd = "dd".utf8Array
    static let dt = "dt".utf8Array
    static let dl = "dl".utf8Array
    static let ol = "ol".utf8Array
    static let ul = "ul".utf8Array
    static let pre = "pre".utf8Array
    static let listing = "listing".utf8Array
    static let address = "address".utf8Array
    static let article = "article".utf8Array
    static let aside = "aside".utf8Array
    static let blockquote = "blockquote".utf8Array
    static let center = "center".utf8Array
    static let dir = "dir".utf8Array
    static let fieldset = "fieldset".utf8Array
    static let figcaption = "figcaption".utf8Array
    static let figure = "figure".utf8Array
    static let footer = "footer".utf8Array
    static let header = "header".utf8Array
    static let hgroup = "hgroup".utf8Array
    static let menu = "menu".utf8Array
    static let nav = "nav".utf8Array
    static let section = "section".utf8Array
    static let summary = "summary".utf8Array
    static let h1 = "h1".utf8Array
    static let h2 = "h2".utf8Array
    static let h3 = "h3".utf8Array
    static let h4 = "h4".utf8Array
    static let h5 = "h5".utf8Array
    static let h6 = "h6".utf8Array
    static let applet = "applet".utf8Array
    static let marquee = "marquee".utf8Array
    static let object = "object".utf8Array
    static let action = "action".utf8Array
    static let prompt = "prompt".utf8Array
    static let comment = "comment".utf8Array
    public static let hash = "#".utf8Array
    static let hashRoot = "#root".utf8Array
    static let ruby = "ruby".utf8Array
    static let rb = "rb".utf8Array
    static let rp = "rp".utf8Array
    static let rt = "rt".utf8Array
    static let rtc = "rtc".utf8Array
    static let page = "page".utf8Array
    static let class_ = "class".utf8Array
    static let table = "table".utf8Array
    static let tbody = "tbody".utf8Array
    static let th = "th".utf8Array
    static let tr = "tr".utf8Array
    static let td = "td".utf8Array
    static let thead = "thead".utf8Array
    static let tfoot = "tfoot".utf8Array
    static let optgroup = "optgroup".utf8Array
    public static let select = "select".utf8Array
    static let form = "form".utf8Array
    static let plaintext = "plaintext".utf8Array
    static let button = "button".utf8Array
    static let image = "image".utf8Array
    static let value = "value".utf8Array
    static let input = "input".utf8Array
    static let type = "type".utf8Array
    static let hidden = "hidden".utf8Array
    public static let id = "id".utf8Array
    static let src = "src".utf8Array
    static let alt = "alt".utf8Array
    static let caption = "caption".utf8Array
    static let hr = "hr".utf8Array
    static let abbr = "abbr".utf8Array
    static let svg = "svg".utf8Array
    static let isindex = "isindex".utf8Array
    static let label = "label".utf8Array
    static let xmp = "xmp".utf8Array
    static let textarea = "textarea".utf8Array
    static let iframe = "iframe".utf8Array
    static let noembed = "noembed".utf8Array
    static let noframes = "noframes".utf8Array
    static let noscript = "noscript".utf8Array
    static let embed = "embed".utf8Array
    static let option = "option".utf8Array
    static let math = "math".utf8Array
    public static let data = "data".utf8Array
    static let strong = "strong".utf8Array
    static let code = "code".utf8Array
    static let sarcasm = "sarcasm".utf8Array // Huh
    public static let name = "name".utf8Array
    static let i = "i".utf8Array
    static let nobr = "nobr".utf8Array
    static let col = "col".utf8Array
    static let colgroup = "colgroup".utf8Array
    static let em = "em".utf8Array
    static let small = "small".utf8Array
    static let frame = "frame".utf8Array
    static let sub = "sub".utf8Array
    static let sup = "sup".utf8Array
    static let base = "base".utf8Array
    static let time = "time".utf8Array
    static let href = "href".utf8Array
    static let meter = "meter".utf8Array
    static let b = "b".utf8Array
    static let style = "style".utf8Array
    public static let title = "title".utf8Array
    static let script = "script".utf8Array
    static let br = "br".utf8Array
    static let frameset = "frameset".utf8Array
    static let blobColon = "blob:".utf8Array
    static let absPrefix = "abs:".utf8Array
    static let true_ = "true".utf8Array

    static let tagLookup: [String: [UInt8]] = {
        let entries: [(String, [UInt8])] = [
            ("html", html),
            ("head", head),
            ("meta", meta),
            ("body", body),
            ("cite", cite),
            ("a", a),
            ("p", p),
            ("div", div),
            ("li", li),
            ("span", span),
            ("img", img),
            ("dd", dd),
            ("dt", dt),
            ("dl", dl),
            ("ol", ol),
            ("ul", ul),
            ("pre", pre),
            ("listing", listing),
            ("address", address),
            ("article", article),
            ("aside", aside),
            ("blockquote", blockquote),
            ("center", center),
            ("dir", dir),
            ("fieldset", fieldset),
            ("figcaption", figcaption),
            ("figure", figure),
            ("footer", footer),
            ("header", header),
            ("hgroup", hgroup),
            ("menu", menu),
            ("nav", nav),
            ("section", section),
            ("summary", summary),
            ("h1", h1),
            ("h2", h2),
            ("h3", h3),
            ("h4", h4),
            ("h5", h5),
            ("h6", h6),
            ("applet", applet),
            ("marquee", marquee),
            ("object", object),
            ("ruby", ruby),
            ("rb", rb),
            ("rp", rp),
            ("rt", rt),
            ("rtc", rtc),
            ("table", table),
            ("tbody", tbody),
            ("th", th),
            ("tr", tr),
            ("td", td),
            ("thead", thead),
            ("tfoot", tfoot),
            ("optgroup", optgroup),
            ("select", select),
            ("form", form),
            ("plaintext", plaintext),
            ("button", button),
            ("input", input),
            ("caption", caption),
            ("hr", hr),
            ("abbr", abbr),
            ("svg", svg),
            ("isindex", isindex),
            ("label", label),
            ("xmp", xmp),
            ("textarea", textarea),
            ("iframe", iframe),
            ("noembed", noembed),
            ("noframes", noframes),
            ("noscript", noscript),
            ("embed", embed),
            ("option", option),
            ("math", math),
            ("data", data),
            ("strong", strong),
            ("sarcasm", sarcasm),
            ("i", i),
            ("nobr", nobr),
            ("col", col),
            ("colgroup", colgroup),
            ("em", em),
            ("small", small),
            ("frame", frame),
            ("sub", sub),
            ("sup", sup),
            ("base", base),
            ("time", time),
            ("meter", meter),
            ("b", b),
            ("style", style),
            ("title", title),
            ("script", script),
            ("br", br),
            ("frameset", frameset)
        ]
        var map: [String: [UInt8]] = [:]
        map.reserveCapacity(entries.count)
        for (key, value) in entries {
            map[key] = value
        }
        return map
    }()

    static let attributeLookup: [String: [UInt8]] = {
        let entries: [(String, [UInt8])] = [
            ("class", class_),
            ("id", id),
            ("href", href),
            ("src", src),
            ("alt", alt),
            ("title", title),
            ("style", style),
            ("name", name),
            ("value", value),
            ("type", type),
            ("action", action)
        ]
        var map: [String: [UInt8]] = [:]
        map.reserveCapacity(entries.count)
        for (key, value) in entries {
            map[key] = value
        }
        return map
    }()
}

enum UTF8ArraySlices {
    static let whitespace = UTF8Arrays.whitespace[...]
    static let bang = UTF8Arrays.bang[...]
    static let equalSign = UTF8Arrays.equalSign[...]
    static let ampersand = UTF8Arrays.ampersand[...]
    static let hyphen = UTF8Arrays.hyphen[...]
    static let doubleHyphen = UTF8Arrays.doubleHyphen[...]
    static let doubleHyphenBang = UTF8Arrays.doubleHyphenBang[...]
    static let underscore = UTF8Arrays.underscore[...]
    static let semicolon = UTF8Arrays.semicolon[...]
    static let questionMark = UTF8Arrays.questionMark[...]
    static let forwardSlash = UTF8Arrays.forwardSlash[...]
    static let selfClosingTagEnd = UTF8Arrays.selfClosingTagEnd[...]
    static let endTagStart = UTF8Arrays.endTagStart[...]
    static let tagStart = UTF8Arrays.tagStart[...]
    static let tagStartBang = UTF8Arrays.tagStartBang[...]
    static let tagEnd = UTF8Arrays.tagEnd[...]
    static let attributeEqualsQuoteMark = UTF8Arrays.attributeEqualsQuoteMark[...]
    static let quoteMark = UTF8Arrays.quoteMark[...]
    public static let html = UTF8Arrays.html[...]
    static let head = UTF8Arrays.head[...]
    static let meta = UTF8Arrays.meta[...]
    public static let body = UTF8Arrays.body[...]
    static let cite = UTF8Arrays.cite[...]
    static let abbr = UTF8Arrays.abbr[...]
    public static let data = UTF8Arrays.data[...]
    static let strong = UTF8Arrays.strong[...]
    static let code = UTF8Arrays.code[...]
    static let sub = UTF8Arrays.sub[...]
    static let sup = UTF8Arrays.sup[...]
    static let b = UTF8Arrays.b[...]
    static let i = UTF8Arrays.i[...]
    static let meter = UTF8Arrays.meter[...]
    static let a = UTF8Arrays.a[...]
    static let p = UTF8Arrays.p[...]
    static let li = UTF8Arrays.li[...]
    static let em = UTF8Arrays.em[...]
    static let time = UTF8Arrays.time[...]
    static let small = UTF8Arrays.small[...]
    static let span = UTF8Arrays.span[...]
    static let img = UTF8Arrays.img[...]
    static let action = UTF8Arrays.action[...]
    static let prompt = UTF8Arrays.prompt[...]
    static let comment = UTF8Arrays.comment[...]
    public static let hash = UTF8Arrays.hash[...]
    static let hashRoot = UTF8Arrays.hashRoot[...]
    static let ruby = UTF8Arrays.ruby[...]
    static let rb = UTF8Arrays.rb[...]
    static let rp = UTF8Arrays.rp[...]
    static let rt = UTF8Arrays.rt[...]
    static let rtc = UTF8Arrays.rtc[...]
    static let page = UTF8Arrays.page[...]
    static let dd = UTF8Arrays.dd[...]
    static let dt = UTF8Arrays.dt[...]
    static let dl = UTF8Arrays.dl[...]
    static let ol = UTF8Arrays.ol[...]
    static let ul = UTF8Arrays.ul[...]
    static let pre = UTF8Arrays.pre[...]
    static let listing = UTF8Arrays.listing[...]
    static let address = UTF8Arrays.address[...]
    static let article = UTF8Arrays.article[...]
    static let aside = UTF8Arrays.aside[...]
    static let blockquote = UTF8Arrays.blockquote[...]
    static let center = UTF8Arrays.center[...]
    static let dir = UTF8Arrays.dir[...]
    static let fieldset = UTF8Arrays.fieldset[...]
    static let figcaption = UTF8Arrays.figcaption[...]
    static let figure = UTF8Arrays.figure[...]
    static let footer = UTF8Arrays.footer[...]
    static let header = UTF8Arrays.header[...]
    static let hgroup = UTF8Arrays.hgroup[...]
    static let menu = UTF8Arrays.menu[...]
    static let nav = UTF8Arrays.nav[...]
    static let section = UTF8Arrays.section[...]
    static let summary = UTF8Arrays.summary[...]
    static let h1 = UTF8Arrays.h1[...]
    static let h2 = UTF8Arrays.h2[...]
    static let h3 = UTF8Arrays.h3[...]
    static let h4 = UTF8Arrays.h4[...]
    static let h5 = UTF8Arrays.h5[...]
    static let h6 = UTF8Arrays.h6[...]
    static let applet = UTF8Arrays.applet[...]
    static let marquee = UTF8Arrays.marquee[...]
    static let object = UTF8Arrays.object[...]
    static let class_ = UTF8Arrays.class_[...]
    static let table = UTF8Arrays.table[...]
    static let tbody = UTF8Arrays.tbody[...]
    static let th = UTF8Arrays.th[...]
    static let tr = UTF8Arrays.tr[...]
    static let td = UTF8Arrays.td[...]
    static let thead = UTF8Arrays.thead[...]
    static let tfoot = UTF8Arrays.tfoot[...]
    static let optgroup = UTF8Arrays.optgroup[...]
    public static let select = UTF8Arrays.select[...]
    static let form = UTF8Arrays.form[...]
    static let plaintext = UTF8Arrays.plaintext[...]
    static let button = UTF8Arrays.button[...]
    static let image = UTF8Arrays.image[...]
    static let value = UTF8Arrays.value[...]
    static let nobr = UTF8Arrays.nobr[...]
    static let input = UTF8Arrays.input[...]
    static let type = UTF8Arrays.type[...]
    static let hidden = UTF8Arrays.hidden[...]
    static let caption = UTF8Arrays.caption[...]
    static let hr = UTF8Arrays.hr[...]
    static let svg = UTF8Arrays.svg[...]
    static let isindex = UTF8Arrays.isindex[...]
    static let label = UTF8Arrays.label[...]
    static let xmp = UTF8Arrays.xmp[...]
    static let textarea = UTF8Arrays.textarea[...]
    static let iframe = UTF8Arrays.iframe[...]
    static let noembed = UTF8Arrays.noembed[...]
    static let noframes = UTF8Arrays.noframes[...]
    static let noscript = UTF8Arrays.noscript[...]
    static let embed = UTF8Arrays.embed[...]
    static let option = UTF8Arrays.option[...]
    static let math = UTF8Arrays.math[...]
    static let sarcasm = UTF8Arrays.sarcasm[...]
    public static let name = UTF8Arrays.name[...]
    static let col = UTF8Arrays.col[...]
    static let colgroup = UTF8Arrays.colgroup[...]
    static let frame = UTF8Arrays.frame[...]
    static let base = UTF8Arrays.base[...]
    static let href = UTF8Arrays.href[...]
    static let style = UTF8Arrays.style[...]
    public static let title = UTF8Arrays.title[...]
    static let script = UTF8Arrays.script[...]
    static let br = UTF8Arrays.br[...]
    static let frameset = UTF8Arrays.frameset[...]
    static let blobColon = UTF8Arrays.blobColon[...]
    static let true_ = UTF8Arrays.true_[...]
}

extension Array where Element == UInt8 {
    /// Compares a region of self to a region of another UTF8 string, optionally case-insensitive (ASCII only).
    func regionMatches(
        ignoreCase: Bool,
        selfOffset: Int,
        other: [UInt8],
        otherOffset: Int,
        targetLength: Int
    ) -> Bool {
        // Bounds check
        if selfOffset < 0 || otherOffset < 0 ||
            selfOffset > self.count - targetLength ||
            otherOffset > other.count - targetLength {
            return false
        }
        for i in 0..<targetLength {
            var a = self[selfOffset + i]
            var b = other[otherOffset + i]
            if ignoreCase {
                // ASCII case folding (A-Z 65-90, a-z 97-122)
                if a >= 65 && a <= 90 { a += 32 }
                if b >= 65 && b <= 90 { b += 32 }
            }
            if a != b {
                return false
            }
        }
        return true
    }
}
