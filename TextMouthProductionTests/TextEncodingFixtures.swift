import Foundation
@testable import TextMouth

// MARK: - Text Encoding Fixtures

/// Paragraphs of ordinary prose in many languages, each with the legacy
/// encodings a text file in that language is plausibly saved in (FMT16):
/// what the tests of the encoding guesser and of the import of such files
/// write as bytes and expect to read back as the same text.
///
/// The paragraphs are written for the tests. Each has a few hundred
/// characters, the size of a short chapter's opening, with the capitals,
/// punctuation, and sprinkling of accented letters real writing has.
enum TextEncodingFixtures {

    /// A paragraph, and the encodings, by their IANA names, it is saved in.
    struct Paragraph {
        let language: String
        let text: String
        let encodings: [String]
    }

    /// The encodings Windows-1252 reads correctly: a file saved in either is
    /// not guessed at.
    static let defaultEncodings: Set<String> = ["windows-1252", "iso-8859-1"]

    // MARK: Making Bytes

    /// The encoding Core Foundation knows by the IANA name `name`.
    static func encoding(named name: String) -> String.Encoding? {
        let coreFoundationEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard coreFoundationEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(coreFoundationEncoding))
    }

    /// `text` without the characters `encoding` cannot write (a Cyrillic
    /// text in CP866 has no guillemets, say), so that what a file in the
    /// encoding holds is known exactly.
    static func writable(_ text: String, in encoding: String.Encoding) -> String {
        var kept = ""
        var writableCache: [Character: Bool] = [:]
        for character in text {
            let isWritable = writableCache[character]
                ?? (String(character).data(using: encoding, allowLossyConversion: false) != nil)
            writableCache[character] = isWritable
            if isWritable { kept.append(character) }
        }
        return kept
    }

    // MARK: Paragraphs

    static let paragraphs: [Paragraph] = [
        Paragraph(language: "English", text: """
            It wasn’t until the autumn of 1998 that the café on the corner finally closed—and nobody, not even the regulars, seemed surprised. “We’ve had a good run,” the owner told me, wiping the counter one last time. Her résumé, pinned beside the till, listed thirty years of work: waitress, baker, bookkeeper. A naïve visitor might have taken the place for a museum; the menu still quoted prices in pounds (£2.50 for a pot of tea) and, since the euro came in, €3.20 as well. I left with a bag of rolls and a promise to write.
            """, encodings: ["windows-1252", "macintosh"]),

        Paragraph(language: "English in Latin 1", text: """
            The train to the coast leaves at nine, and the guard says it will not wait for anyone. We packed sandwiches, a flask of tea, two umbrellas and far too many books, because the forecast promised rain and nothing else. By noon the carriage had emptied; a boy across the aisle was drawing the hills in a notebook, and an old man dozed with his hat over his eyes. At the buffet a café au lait cost £2, and the waiter, a naïve young man from Zürich, apologised twice for the delay. Nobody spoke much. It was, I thought, exactly the kind of day that people later remember as perfect without being able to say why.
            """, encodings: ["windows-1252", "iso-8859-1"]),

        Paragraph(language: "French", text: """
            Il était une fois, dans un petit village près de Lyon, une boulangère qui se levait chaque matin avant l’aube pour préparer le pain. Les habitants, qui l’aimaient beaucoup, lui apportaient parfois des œufs, des légumes du jardin ou quelques fleurs. « Ce n’est pas grand-chose, disaient-ils, mais c’est de bon cœur ! » Elle les remerciait avec un sourire, puis retournait à son fournil où la chaleur du four lui rappelait les étés de son enfance. Être utile, voilà ce qu’elle avait toujours voulu : à quatre-vingts ans, elle n’avait pas changé d’avis.
            """, encodings: ["windows-1252", "macintosh"]),

        Paragraph(language: "French in Latin 9", text: """
            Le cœur de la ville bat au rythme des marchés : ce samedi, les étals débordaient de fruits, de fromages et de pains de seigle à 3,50 €. Les clients, venus de tout le quartier, discutaient de la météo, des prix et des vacances prochaines, sans jamais se presser. Une vieille dame, chargée d’œufs frais, expliquait à un jeune garçon comment reconnaître une bonne tomate ; il l’écoutait, très sérieux, en notant tout dans son carnet. Vers midi, les cloches ont sonné et la place s’est vidée comme par enchantement.
            """, encodings: ["iso-8859-15", "windows-1252"]),

        Paragraph(language: "German", text: """
            Über den Dächern der Stadt zog an diesem Abend ein Gewitter auf, und die Straßen leerten sich schneller, als man es für möglich gehalten hätte. Im kleinen Café an der Ecke saßen nur noch zwei ältere Herren, die über Fußball und die Preise für Äpfel stritten. „Früher war alles günstiger“, sagte der eine. „Aber auch größer als heute?“, fragte der andere und lachte. Draußen fielen die ersten schweren Tropfen, und der Wirt schloss die Fenster, löschte das Licht über der Theke und stellte die Stühle auf die Tische.
            """, encodings: ["windows-1252", "macintosh"]),

        Paragraph(language: "German in Latin 1", text: """
            Über den Dächern der Stadt zog an diesem Abend ein Gewitter auf, und die Straßen leerten sich schneller, als man es für möglich gehalten hätte. Im kleinen Café an der Ecke saßen nur noch zwei ältere Herren, die über Fußball und die Preise für Äpfel stritten. "Früher war alles günstiger", sagte der eine. "Aber auch größer als heute?", fragte der andere und lachte. Draußen fielen die ersten schweren Tropfen, und der Wirt schloss die Fenster, löschte das Licht über der Theke und stellte die Stühle auf die Tische.
            """, encodings: ["iso-8859-1", "windows-1252"]),

        Paragraph(language: "Spanish", text: """
            ¿Dónde está la biblioteca? —preguntó el niño, con la mochila al hombro y un bocadillo de jamón en la mano. La señora que atendía el quiosco le señaló una calle estrecha, sombreada por los árboles. «Al final verás una puerta verde», dijo. Aquella mañana de septiembre, el pequeño Álvaro todavía no sabía que el pasillo de libros viejos que iba a descubrir le cambiaría la vida. Había palabras por todas partes: canciones, poemas, años de conversaciones guardadas en papel. ¡Qué maravilla!, pensó, y empezó a leer.
            """, encodings: ["windows-1252", "iso-8859-1", "macintosh"]),

        Paragraph(language: "Portuguese", text: """
            A manhã começou com chuva fina, e os pescadores da vila, acostumados a esperar, sentaram-se junto ao cais a remendar redes. Não havia pressa: o mar, dizia o mais velho, tem memória longa e paciência de sobra. As crianças, entretanto, corriam descalças entre as barcas, apanhando conchas e discutindo quem encontrara a mais bonita. Ao meio-dia, a avó trouxe pão quente, queijo e uma jarra de limonada, e todos comeram sem falar, ouvindo o vento e o som das ondas contra a pedra.
            """, encodings: ["windows-1252", "iso-8859-1", "macintosh"]),

        Paragraph(language: "Italian", text: """
            Nel piccolo paese in cima alla collina, la domenica mattina le campane suonavano così forte che anche i gatti, più pigri del solito, alzavano la testa. Le donne andavano a messa con il vestito buono; gli uomini, invece, preferivano aspettare sulla piazza, davanti al caffè, discutendo di politica e del tempo. Perché mai cambiare abitudini? «Qui è sempre andata così», diceva il vecchio, e nessuno trovava niente da obiettare. Più tardi, a pranzo, la pasta fumava nei piatti e la città, laggiù, sembrava lontanissima.
            """, encodings: ["windows-1252", "iso-8859-1", "macintosh"]),

        Paragraph(language: "Dutch", text: """
            De trein naar Utrecht had veertig minuten vertraging, en op het perron stonden mensen met paraplu’s en koffie in kartonnen bekers te wachten. Een jongen met een grote rugzak las een boek over de geschiedenis van de zeevaart; naast hem zat een oude vrouw te breien. “Het is altijd hetzelfde,” zei ze zacht, “eerst regent het, dan is er een storing, en daarna zijn we vergeten waar we naartoe wilden.” Ze lachte, en de jongen, die haar niet goed verstond, lachte beleefd terug. Ook de café-eigenaar keek op, geïnteresseerd.
            """, encodings: ["windows-1252", "macintosh"]),

        Paragraph(language: "Swedish", text: """
            Sommaren i Småland börjar egentligen först när ladugårdsdörrarna står öppna och doften av nyslaget hö drar över åkrarna. Barnen springer barfota till sjön, där vattnet fortfarande är kallt efter våren, och de äldre sitter på verandan med kaffe och kanelbullar. ”Det är här man hör hemma”, säger farmor och tittar ut över ängen. Några kor betar långsamt vid hagen, och i fjärran hörs en traktor som tuffar fram längs den smala grusvägen mot byn.
            """, encodings: ["windows-1252", "macintosh"]),

        Paragraph(language: "Danish", text: """
            Det var en kold morgen i Århus, og tågene gik som altid for sent. På perronen stod en ældre mand med hat og stok og så ud over byens tage, hvor røgen steg lige op fra skorstenene. »Det bliver en hård vinter«, mumlede han for sig selv. Hans datter, der havde taget sig fri fra arbejdet for at følge ham, smilede og rakte ham en kop varm kaffe fra termokanden. Æbleskiver, sagde hun, venter hjemme hos mor, og så er det jul inden længe.
            """, encodings: ["windows-1252", "iso-8859-1", "macintosh"]),

        Paragraph(language: "Finnish", text: """
            Kylän vanhin talo seisoi mäen päällä, ja sen ikkunoista näkyi koko järvi aina vastarannan metsään asti. Aamuisin isoäiti keitti kahvia ja leipoi pullaa, ja lapset heräsivät tuoksuun, vaikka olisivat halunneet nukkua vielä hetken. Tänä syksynä sato oli ollut hyvä, joten kellarissa oli perunoita, omenoita ja purkkikaupalla marjahilloa. Ulkona tuuli kävi hiljaa ja lehdet putoilivat pihalle keltaisina.
            """, encodings: ["windows-1252", "iso-8859-1", "macintosh"]),

        Paragraph(language: "Polish", text: """
            W niedzielny poranek wszyscy mieszkańcy kamienicy zbierali się na podwórku, żeby wspólnie posprzątać po zimie. Pani Zofia przyniosła wiadro i szczotkę, pan Józef – drabinę, a dzieci pobiegły po stare gazety. „Gdyby nie my, nikt by tu nie zamiótł”, powiedziała sąsiadka z drugiego piętra i zaśmiała się głośno. Pod wieczór, kiedy słońce zaszło za dachy, na stole pojawiły się ciasto, herbata i żółty ser; ktoś zaczął grać na gitarze, a ktoś inny śpiewał, fałszując zupełnie szczerze.
            """, encodings: ["windows-1250", "iso-8859-2"]),

        Paragraph(language: "Czech", text: """
            Příliš žluťoučký kůň úpěl ďábelské ódy, tak začíná věta, kterou se učí všichni žáci při psaní na stroji. V malé vesnici pod horami žila stará paní, která každé ráno krmila slepice a zpívala si staré písničky. Děti ji měly rády, protože uměla vyprávět pohádky o vodnících, čarodějnicích a hodných čertech. „Jen počkejte, až bude dlouhá zima,“ říkala jim, „to si budeme povídat celé večery.“ A skutečně, když napadl první sníh, sešli se všichni u ní v kuchyni.
            """, encodings: ["windows-1250", "iso-8859-2"]),

        Paragraph(language: "Hungarian", text: """
            A kis falu főterén minden délután összegyűltek az öregek, hogy megbeszéljék a nap híreit. Az egyik szerint idén korán jön a tél; a másik azt állította, hogy a gyümölcsfák még sosem virágoztak ilyen szépen. Közben a gyerekek a kút körül játszottak, és nevetésük végigfutott a szűk utcákon. Este a lámpák egyenként kigyúltak, a templom harangja háromszor kondult, és a falu lassan elcsendesedett. Másnap mindenki ugyanúgy folytatta, ahogyan azelőtt.
            """, encodings: ["windows-1250", "iso-8859-2"]),

        Paragraph(language: "Russian", text: """
            В то утро над городом стоял густой туман, и трамваи медленно ползли по мокрым рельсам, позвякивая на поворотах. Старик в потёртом пальто сидел у окна и читал газету, хотя давно уже не понимал, зачем ему нужны чужие новости. «Всё это было и раньше», — подумал он и улыбнулся. На соседней скамейке две девочки спорили о том, кто первым увидит снег. Когда трамвай остановился, в вагон вошла женщина с большой корзиной яблок, и по салону разлился тонкий кисловатый запах осени.
            """, encodings: ["windows-1251", "koi8-r", "cp866", "iso-8859-5", "x-mac-cyrillic"]),

        Paragraph(language: "Russian without quotation marks", text: """
            Весной в нашем дворе всегда пахло мокрой землёй и свежей краской. Соседи выходили с вёдрами и лопатами, красили скамейки, сажали цветы и спорили о том, где лучше поставить качели. Дети путались под ногами, а бабушка из второго подъезда раздавала всем пирожки с капустой. К вечеру двор преображался: чистые дорожки, яркие клумбы, смех и запах чая из открытых окон. Никто не хотел расходиться по домам, и разговоры затягивались допоздна.
            """, encodings: ["windows-1251", "koi8-r", "cp866", "iso-8859-5", "x-mac-cyrillic"]),

        Paragraph(language: "Ukrainian", text: """
            Над селом повільно підіймався дим із печей, а десь далеко за садами співали півні. Баба Галя вийшла на ґанок із глечиком молока і довго дивилася на дорогу, якою мали повернутися з ярмарку сини. «Не хвилюйся, — казав дід, — вони обов’язково приїдуть до вечора». Але вона все одно хвилювалася, бо в її серці жила тривога, яку не втішити словами. Коли ж надвечір почувся скрип воза, вона усміхнулась і поспішила до воріт.
            """, encodings: ["windows-1251", "koi8-u"]),

        Paragraph(language: "Bulgarian", text: """
            През лятото на онази година целият квартал се събираше вечер пред блока, където старият господин разказваше истории от младостта си. Децата седяха на стълбите и го слушаха с широко отворени очи, а майките носеха чай и банички от къщи. „Животът е като река“, казваше той, „понякога тече бавно, друг път те отнася.“ После се смееше с глас и наливаше още една чаша, докато над покривите изгряваха първите звезди.
            """, encodings: ["windows-1251"]),

        Paragraph(language: "Greek", text: """
            Το καλοκαίρι εκείνης της χρονιάς το χωριό γέμισε επισκέπτες από την Αθήνα, και η ταβέρνα δίπλα στη θάλασσα δεν είχε ποτέ ούτε ένα άδειο τραπέζι. Ο ιδιοκτήτης, ένας ήσυχος άνθρωπος με λευκά μαλλιά, σέρβιρε ψάρια, ελιές και κρασί, και κάθε βράδυ έλεγε στους πελάτες την ίδια ιστορία για το καράβι που βούλιαξε κάποτε στον κόλπο. «Δεν είναι ψέμα», έλεγε, «το είδε ο παππούς μου». Κανείς δεν τον πίστευε, αλλά όλοι γελούσαν.
            """, encodings: ["windows-1253", "iso-8859-7"]),

        Paragraph(language: "Turkish", text: """
            Sabah erkenden kalkıp çay demledi, sonra balkona çıkıp denizi seyretti. Şehrin üzerinde ince bir sis vardı; vapurlar yavaşça iskeleden ayrılıyor, martılar çığlık atarak dalgaların üstünde dönüyordu. “Bugün güzel bir gün olacak,” dedi kendi kendine. Komşunun çocukları sokakta top oynuyor, bakkal tezgâhın başında gazete okuyordu. İstanbul’un o eski mahallesinde zaman başka türlü akardı: kimse acele etmez, herkes birbirinin halini hatırını sorardı.
            """, encodings: ["windows-1254", "iso-8859-9"]),

        Paragraph(language: "Hebrew", text: """
            בבוקר קר של חורף ישבה סבתא ליד החלון, שתתה תה חם והביטה בילדים שרצו לבית הספר. היא זכרה את הימים שבהם הייתה בעצמה ילדה, ואת הדרך הארוכה שעברה מאז. "הכול משתנה," אמרה בשקט, "אבל התה נשאר אותו הדבר." אחר כך קמה, פתחה את הארון והוציאה קופסה ישנה מלאה במכתבים צהובים. בחוץ התחיל לרדת שלג דק, והרחוב כולו נעשה שקט.
            """, encodings: ["windows-1255", "iso-8859-8"]),

        Paragraph(language: "Arabic", text: """
            في صباح يوم الجمعة، خرج الأطفال إلى الحديقة القريبة من المنزل، وجلس الجد تحت شجرة التين العتيقة يحكي لهم عن أيام الطفولة. كانت الشمس دافئة، والهواء مليئاً برائحة الخبز الطازج القادمة من الحي القديم. «الحياة بسيطة»، قال الجد، «إذا عرفنا كيف نصغي». ضحك الأطفال، ثم عادوا يلعبون بين الأشجار، بينما كانت الجدة تعد الغداء في المطبخ الصغير.
            """, encodings: ["windows-1256", "iso-8859-6"]),

        Paragraph(language: "Lithuanian", text: """
            Ryte miestas pabudo labai anksti, nes iš upės kilo tirštas rūkas, o gatvėse jau girdėjosi pirmųjų tramvajų skambesys. Senas knygius atidarė savo parduotuvę, užkaitė arbatos ir atsisėdo prie lango, žiūrėdamas į pro šalį einančius žmones. „Šiandien bus ramu“, tarė jis sau. Tačiau jau po valandos durys prasivėrė, ir į vidų įėjo jauna moteris, ieškanti senos knygos apie žvaigždes.
            """, encodings: ["windows-1257", "iso-8859-13"]),

        Paragraph(language: "Thai", text: """
            เช้าวันนั้นอากาศเย็นสบาย ชาวบ้านเริ่มออกมาตั้งแผงขายผักและผลไม้ที่ตลาดริมคลองกันแต่เช้า เด็กๆ วิ่งเล่นกันอยู่ใกล้ๆ ขณะที่คุณยายนั่งปอกมะม่วงอยู่ใต้ร่มไม้ เสียงเรือหางยาวดังมาแต่ไกล ทำให้ทุกคนหันไปมอง แล้วยิ้มให้กันอย่างอบอุ่น พอสายขึ้น แดดเริ่มร้อน คนในตลาดก็ยิ่งคึกคักมากขึ้นเรื่อยๆ
            """, encodings: ["windows-874", "iso-8859-11"]),

        Paragraph(language: "Japanese", text: """
            朝の駅は、いつもより静かだった。ホームに立っていた老人は、遠くから近づいてくる電車の音に耳をすませ、小さくうなずいた。「今日もまた、同じ一日が始まるのだな」と彼はつぶやいた。しかし、窓の外に広がる景色は毎日少しずつ違っている。季節は確かに移り変わり、街の人々もそれぞれの物語を抱えて歩いていく。電車が到着すると、彼はゆっくりと乗り込み、窓際の席に腰を下ろした。
            """, encodings: ["shift_jis", "euc-jp", "windows-31j"]),

        Paragraph(language: "Simplified Chinese", text: """
            清晨的街道上，人还不多，卖早点的小摊已经冒起了热气。老张推着自行车慢慢走过，向熟悉的摊主点头打招呼。“今天天气不错。”他笑着说。摊主一边忙着包包子，一边回答：“是啊，难得不下雨。”不远处的公园里，几位老人正在打太极拳，动作缓慢而柔和。一天就这样开始了，平静而又充满生活的气息。
            """, encodings: ["gbk", "gb18030", "gb2312"]),

        Paragraph(language: "Traditional Chinese", text: """
            清晨的街道上，人還不多，賣早點的小攤已經冒起了熱氣。老張推著腳踏車慢慢走過，向熟悉的攤主點頭打招呼。「今天天氣不錯。」他笑著說。攤主一邊忙著包包子，一邊回答：「是啊，難得不下雨。」不遠處的公園裡，幾位老人正在打太極拳，動作緩慢而柔和。一天就這樣開始了，平靜而又充滿生活的氣息。
            """, encodings: ["big5", "cp950"]),

        Paragraph(language: "Korean", text: """
            아침 일찍 일어난 할머니는 마루에 앉아 천천히 차를 마셨다. 마당에는 어제 내린 비가 아직 마르지 않았고, 감나무 가지 끝에는 붉은 열매가 무겁게 매달려 있었다. “올해는 감이 참 많이 열렸구나.” 할머니는 혼잣말을 하며 미소를 지었다. 멀리서 아이들의 웃음소리가 들려왔고, 부엌에서는 된장찌개 끓는 냄새가 퍼지고 있었다.
            """, encodings: ["euc-kr", "cp949"]),
    ]
}
