import Foundation

extension ScheduleSpeech {
    /// A phrase in any language the app speaks, said again in the English words the reader knows:
    /// "平日 7:30", "werktags 7:30", "co 2 godziny" and "20분 뒤" become "weekdays 7:30",
    /// "every 2 hours" and "in 20 min". Every example the sheet's own placeholder gives, in every
    /// language, has to read as what it says, or the example teaches a phrase that is misread.
    static func english(_ phrase: String) -> String {
        var text = " " + phrase.precomposedStringWithCompatibilityMapping.lowercased() + " "
        for (expression, english) in rewrites {
            let range = NSRange(text.startIndex..., in: text)
            text = expression.stringByReplacingMatches(in: text, range: range, withTemplate: english)
        }
        return text
    }

    static let rewrites: [(NSRegularExpression, String)] = phrasebook.compactMap { pattern, english in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, english) }
    }

    /// A whole word in a language that spaces its words, so "mar" is never read out of "martes".
    private static func word(_ alternatives: String) -> String {
        #"(?<![\p{L}'’])(?:"# + alternatives + #")(?![\p{L}])"#
    }

    private static let english = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// Ordered: a longer phrase is rewritten before a word inside it ("jeden morgen" before "morgen",
    /// "周一到周五" before "周五", "每周五" before "每"), and a clock is made before anything reads it.
    static let phrasebook: [(String, String)] = clocks + spans + nordicSpans + days + nordicDays + nordicParts + parts + nordicHabits + weekdays + joints + nordicJoints

    private static let hourMark = #"[時时點点시]"#

    private static let clocks: [(String, String)] = [
        (#"[、，。；！？]"#, " "),
        (#"(\d{1,2})\s*"# + hourMark + #"\s*(\d)(?!\d)\s*[分분]"#, " $1:0$2 "),
        (#"(\d{1,2})\s*"# + hourMark + #"\s*(\d{2})\s*[分분]?"#, " $1:$2 "),
        (#"(\d{1,2})\s*"# + hourMark + #"\s*[半반]"#, " $1:30 "),
        (#"(\d{1,2})\s*"# + hourMark + #"(?![間间간])"#, " $1:00 "),
        (#"(?:午後|下午|晚上|夜の?|晩|晚|오후|저녁|밤)\s*(\d{1,2}(?::\d{2})?)"#, " at $1 pm "),
        (#"(?:午前|上午|早上|早晨|朝の?|오전|아침)\s*(\d{1,2}(?::\d{2})?)"#, " at $1 am "),
    ]

    private static let spans: [(String, String)] = [
        (#"(\d+)\s*分\s*[後后]"#, " in $1 min "),
        (#"(\d+)\s*分[钟鐘]\s*[后後]"#, " in $1 min "),
        (#"(\d+)\s*분\s*(?:뒤|후)"#, " in $1 min "),
        (#"(\d+)\s*時間\s*後"#, " in $1 hours "),
        (#"(\d+)\s*(?:个|個)?\s*小[时時]\s*[后後]"#, " in $1 hours "),
        (#"(\d+)\s*시간\s*(?:뒤|후)"#, " in $1 hours "),
        (#"(\d+)\s*日\s*後"#, " in $1 days "),
        (#"(\d+)\s*天\s*[后後]"#, " in $1 days "),
        (#"(\d+)\s*일\s*(?:뒤|후)"#, " in $1 days "),

        (#"(\d+)\s*時間\s*(?:ごと|おき|毎)"#, " every $1 hours "),
        (#"每\s*(\d+)\s*(?:个|個)?\s*小[时時]"#, " every $1 hours "),
        (#"(\d+)\s*시간\s*마다"#, " every $1 hours "),
        (word("alle") + #"\s+(\d+)\s*(?:stunden|std\.?|h)(?![\p{L}])"#, " every $1 hours "),
        (word("(?:a\\s+)?cada") + #"\s+(\d+)\s*(?:horas|h)(?![\p{L}])"#, " every $1 hours "),
        (word("toutes\\s+les") + #"\s+(\d+)\s*(?:heures|h)(?![\p{L}])"#, " every $1 hours "),
        (word("ogni") + #"\s+(\d+)\s*(?:ore|h)(?![\p{L}])"#, " every $1 hours "),
        (word("co") + #"\s+(\d+)\s*(?:godziny|godzin|godz\.?|h)(?![\p{L}])"#, " every $1 hours "),
        (#"毎時|每小[时時]|매시간"#, " hourly "),
        (word("stündlich|jede\\s+stunde|a\\s+cada\\s+hora|cada\\s+hora|toda\\s+hora|toutes\\s+les\\s+heures|chaque\\s+heure|ogni\\s+ora|co\\s+godzin[ęe]"), " hourly "),
    ]

    private static let days: [(String, String)] = [
        (#"平日|工作日|月曜から金曜|周一[到至]周五|週一[到至]週五|평일|주중"#, " weekdays "),
        (word("werktags|wochentags|an\\s+werktagen|werktage|montag\\s+bis\\s+freitag"), " weekdays "),
        (word("entre\\s+semana|(?:d[ií]as\\s+)?laborables|d[ií]as\\s+h[aá]biles|de\\s+lunes\\s+a\\s+viernes"), " weekdays "),
        (word("en\\s+semaine|jours\\s+ouvr[ée]s|jours\\s+ouvrables|du\\s+lundi\\s+au\\s+vendredi"), " weekdays "),
        (word("(?:nei\\s+)?giorni\\s+feriali|feriali|dal\\s+luned[iì]\\s+al\\s+venerd[iì]"), " weekdays "),
        (word("dias\\s+[uú]teis|de\\s+segunda\\s+a\\s+sexta|durante\\s+a\\s+semana"), " weekdays "),
        (word("(?:w\\s+)?dni\\s+(?:robocze|powszednie)|od\\s+poniedzia[lł]ku\\s+do\\s+pi[aą]tku"), " weekdays "),
    ] + cjkWeekdays + [
        (#"毎朝|每天早上|每天早晨|每日早上"#, " every morning "),
        (#"毎晩|毎夜|每天晚上|每晚"#, " every evening "),
        (#"毎日|每天|每日|매일"#, " daily "),
        (word("t[äa]glich|jeden\\s+tag|cada\\s+d[ií]a|todos\\s+los\\s+d[ií]as|a\\s+diario|diariamente|diario"), " daily "),
        (word("tous\\s+les\\s+jours|chaque\\s+jour|quotidiennement|ogni\\s+giorno|tutti\\s+i\\s+giorni"), " daily "),
        (word("todo\\s+dia|todos\\s+os\\s+dias|codziennie|ka[zż]dego\\s+dnia|co\\s+dzie[nń]"), " daily "),
        (word("jeden\\s+morgen|cada\\s+ma[nñ]ana|todas\\s+las\\s+ma[nñ]anas|chaque\\s+matin|tous\\s+les\\s+matins"), " every morning "),
        (word("ogni\\s+mattina|tutte\\s+le\\s+mattine|toda\\s+manh[aã]|todas\\s+as\\s+manh[aã]s|ka[zż]dego\\s+ranka|co\\s+rano"), " every morning "),
        (word("jeden\\s+abend|cada\\s+noche|todas\\s+las\\s+noches|chaque\\s+soir|tous\\s+les\\s+soirs|ogni\\s+sera"), " every evening "),
        (word("toda\\s+noite|todas\\s+as\\s+noites|ka[zż]dego\\s+wieczoru|co\\s+wiecz[oó]r"), " every evening "),
    ]

    private static let parts: [(String, String)] = [
        (#"今夜|今晩|今日の夜|今晚|今天晚上|오늘\s*밤|오늘\s*저녁"#, " tonight "),
        (word("heute\\s+abend|heute\\s+nacht|esta\\s+noche|ce\\s+soir|stasera|stanotte"), " tonight "),
        (word("hoje\\s+[àa]\\s+noite|esta\\s+noite|dzi[sś](?:iaj)?\\s+wieczorem"), " tonight "),
        (word("morgen\\s+fr[üu]h"), " tomorrow morning "),
        (word("morgens|vormittags"), " morning "),
        (word("(?:por|en)\\s+la\\s+ma[nñ]ana|ma[nñ]anas"), " morning "),
        (word("(?:de|pela)\\s+manh[aã]|manh[aã]s"), " morning "),
        (#"明日|あした|明天|내일"#, " tomorrow "),
        (word("morgen|ma[nñ]ana|demain|domani|amanh[aã]|jutro"), " tomorrow "),
        (#"朝|早上|早晨|上午|아침|오전"#, " morning "),
        (word("matin|matins|mattina|mattino|mattine|manh[aã]|rano|rankiem"), " morning "),
        (#"午後|下午|오후"#, " afternoon "),
        (word("nachmittags?|tardes?|apr[eè]s-midi|pomeriggio|po\\s+po[lł]udniu"), " afternoon "),
        (#"夕方|夜|晩|晚上|傍晚|저녁|밤"#, " evening "),
        (word("abends?|noches?|soirs?|sera|sere|noites?|wieczorem|wiecz[oó]r"), " evening "),
        (#"正午|昼|中午|정오|점심"#, " noon "),
        (word("mittags?|mediod[ií]a|midi|mezzogiorno|meio-dia|po[lł]udnie"), " noon "),
        (#"真夜中|午夜|半夜|자정"#, " midnight "),
        (word("mitternacht|medianoche|minuit|mezzanotte|meia-noite|p[oó][lł]noc"), " midnight "),
    ]

    /// "周五", "金曜日", "금요일", and a lone "金" or "금" the way the placeholder writes Friday.
    private static let cjkWeekdays: [(String, String)] = {
        let chinese = ["[日天]", "一", "二", "三", "四", "五", "六"]
        let kanji = ["日", "月", "火", "水", "木", "金", "土"]
        let hangul = ["일", "월", "화", "수", "목", "금", "토"]
        var rules: [(String, String)] = []
        for day in 0..<7 {
            rules.append(("(?:周|週|星期|礼拜|禮拜)" + chinese[day], " \(english[day]) "))
            rules.append((kanji[day] + "曜日?", " \(english[day]) "))
            rules.append((hangul[day] + "\\s*요일", " \(english[day]) "))
        }
        let apart = #"(?![\p{Script=Han}\p{Script=Hangul}])"#
        for day in 1..<7 {
            rules.append((
                #"(?<![\p{Script=Han}\p{Script=Hangul}])(?:"# + kanji[day] + "|" + hangul[day] + ")" + apart,
                " \(english[day]) "))
        }
        return rules
    }()

    /// The seven days in the languages that space their words, Sunday first, rewritten to the English
    /// short name. German says a habit with a trailing s ("freitags"), which makes the phrase repeat;
    /// its two-letter names ("Fr 17:00") are read only before a time, because "so" and "do" are words.
    private static let weekdays: [(String, String)] = {
        let names = [
            "sonntag|domingos?|dimanche|domenica|niedziel[aęi]",
            "montag|lunes|lundi|luned[iì]|segunda(?:-feira)?|poniedzia[lł]e?k[i]?",
            "dienstag|martes|mardi|marted[iì]|ter[cç]a(?:-feira)?|wtorek|wtorki",
            "mittwoch|mi[ée]rcoles|mercredi|mercoled[iì]|quarta(?:-feira)?|[sś]rod[aęy]",
            "donnerstag|jueves|jeudi|gioved[iì]|quinta(?:-feira)?|czwartek|czwartki",
            "freitag|viernes|vendredi|venerd[iì]|sexta(?:-feira)?|pi[aą]tek|pi[aą]tki",
            "samstag|sonnabend|s[aá]bados?|samedi|sabato|sobot[aęy]",
        ]
        let short = [
            "dom|nd|ndz|niedz", "lun|seg|pon|pn", "mar|ter|wt|wto", "mi[ée]|mer|qua|[sś]r|[sś]ro",
            "jue|jeu|gio|qui|czw", "vie|ven|sex|pt|pi[aą]", "s[aá]b|sam|sob|sb",
        ]
        let german = ["so", "mo", "di", "mi", "do", "fr", "sa"]
        var rules: [(String, String)] = []
        for day in 0..<7 {
            let habit = names[day].split(separator: "|").prefix(day == 6 ? 2 : 1).map { "\($0)s" }
            rules.append((word(habit.joined(separator: "|")), " every \(english[day]) "))
            rules.append((word(names[day]), " \(english[day]) "))
            rules.append((word(short[day]) + #"\.?(?=\s|$)"#, " \(english[day]) "))
            rules.append((word(german[day]) + #"\.?(?=\s*\d)"#, " \(english[day]) "))
        }
        return rules
    }()

    private static let joints: [(String, String)] = [
        (#"毎週|毎|每周|每週|每星期|每|매주|매"#, " every "),
        (word("jeden|jede|jedes|cada|todos\\s+los|todas\\s+las|los|chaque|tous\\s+les|toutes\\s+les|ogni|tutti\\s+i|tutte\\s+le"), " every "),
        (word("a\\s+cada|todos\\s+os|todas\\s+as|todo|toda|w\\s+ka[zż]d[yą]|ka[zż]d[yąe]"), " every "),

        (word("alle\\s+ore|alle|all['’]|a\\s+las|a\\s+la|[àa]s|[àa]|o|um") + #"(?=\s*\d)"#, " at "),
        (word("uhr|godz\\.?|godzinie"), " "),

        (word("halbe\\s+stunde|einer\\s+halben\\s+stunde|media\\s+hora|meia\\s+hora|une\\s+demi-heure|demi-heure|mezz['’]?ora|p[oó][lł]\\s+godziny"), " half an hour "),
        (word("un['’]ora"), " an hour "),
        (word("minuten|minutos|minuti|minutes|minut[yę]?"), " min "),
        (word("stunden|horas|heures|ore|godzin[yę]?|godzina"), " hours "),
        (word("stunde|hora|heure|ora|godzin[ęe]"), " hour "),
        (word("tagen|tage|d[ií]as|jours|giorni|dni"), " days "),
        (word("tag|d[ií]a|jour|giorno|dzie[nń]"), " day "),
        (word("una|uno|une|uma|um|un|eine[rm]?|ein") + #"(?=\s+(?:hour|day|half)(?![\p{L}]))"#, " a "),
        (word("dentro\\s+de|daqui\\s+a|en|dans|tra|fra|em|za") + #"(?=\s+(?:\d|a\s|an\s|half\s))"#, " in "),
        (#"(?<!every\s{1,3}|in\s{1,3})(?<![\d:.])(\d{1,2})h(?![\p{L}\d])"#, " $1:00 "),
    ]

    /// Swedish, Danish, Norwegian, Finnish and Icelandic counts: "om 20 min", "20 min päästä", "eftir 20 mín",
    /// "var 2:e timme", "hver 2. time", "2 tunnin välein", "á 2 klukkustunda fresti".
    private static let nordicSpans: [(String, String)] = [
        (word("om") + #"\s+(\d+)\s*min(?:uter|utter|\.)?(?![\p{L}])"#, " in $1 min "),
        (word("om") + #"\s+(\d+)\s*(?:timmar|timme|timer|time|t)(?![\p{L}])"#, " in $1 hours "),
        (word("om") + #"\s+(\d+)\s*(?:dagar|dage|dager|dag|døgn)(?![\p{L}])"#, " in $1 days "),
        (#"(\d+)\s*min(?:uutin|uuttia|\.)?\s+päästä"#, " in $1 min "),
        (#"(\d+)\s*tunnin\s+päästä"#, " in $1 hours "),
        (#"(\d+)\s*päivän\s+päästä"#, " in $1 days "),
        (word("puolen\\s+tunnin\\s+päästä"), " in half an hour "),
        (word("tunnin\\s+päästä"), " in an hour "),
        (word("eftir") + #"\s+(\d+)\s*mín(?:útur|útu|\.)?(?![\p{L}])"#, " in $1 min "),
        (word("eftir") + #"\s+(\d+)\s*(?:klukkustundir|klukkustund|klukkutíma|klst\.?|tíma)(?![\p{L}])"#, " in $1 hours "),
        (word("eftir") + #"\s+(\d+)\s*(?:daga|dag)(?![\p{L}])"#, " in $1 days "),
        (word("var") + #"\s+(\d+)\s*(?::e|:a)?\s*timme(?![\p{L}])"#, " every $1 hours "),
        (word("hver") + #"\s+(\d+)\.?\s*time(?![\p{L}])"#, " every $1 hours "),
        (#"(\d+)\s*tunnin\s+välein"#, " every $1 hours "),
        (word("á") + #"\s+(\d+)\s*(?:klukkustunda|klukkutíma|tíma)\s+fresti"#, " every $1 hours "),
        (word("varje\\s+timme|en\\s+gång\\s+i\\s+timmen|hver\\s+time|tunnin\\s+välein|joka\\s+tunti|á\\s+klukkutíma\\s+fresti|á\\s+klukkustundar\\s+fresti"), " hourly "),
    ]

    private static let nordicDays: [(String, String)] = [
        (word("vardagar|på\\s+vardagar|måndag\\s+till\\s+fredag|hverdage|på\\s+hverdage|hverdager|på\\s+hverdager|ukedager|mandag\\s+til\\s+fredag|arkisin|arkipäivisin|maanantaista\\s+perjantaihin|virka\\s+daga|á\\s+virkum\\s+dögum|virkum\\s+dögum|mánudaga\\s+til\\s+föstudaga"), " weekdays "),
        (word("varje\\s+morgon|hver\\s+morgen|joka\\s+aamu|aamuisin|á\\s+hverjum\\s+morgni"), " every morning "),
        (word("varje\\s+kväll|hver\\s+aften|hver\\s+kveld|joka\\s+ilta|iltaisin|á\\s+hverju\\s+kvöldi"), " every evening "),
        (word("varje\\s+dag|dagligen|hver\\s+dag|dagligt|daglig|joka\\s+päivä|päivittäin|á\\s+hverjum\\s+degi|daglega"), " daily "),
    ]

    /// Ahead of the German words, so "i morgen" is never read as "i" before a German "morgen".
    private static let nordicParts: [(String, String)] = [
        (word("i\\s+kväll|ikväll|i\\s+aften|i\\s+kveld|tänä\\s+iltana|tänään\\s+illalla|í\\s+kvöld"), " tonight "),
        (word("i\\s+morgon\\s+bitti|imorgon\\s+bitti|i\\s+morgen\\s+tidlig|huomenna\\s+aamulla|í\\s+fyrramálið"), " tomorrow morning "),
        (word("i\\s+morgon|imorgon|i\\s+morgen|huomenna|á\\s+morgun"), " tomorrow "),
        (word("på\\s+morgonen|om\\s+morgenen|aamulla|um\\s+morguninn"), " morning "),
        (word("på\\s+eftermiddagen|om\\s+eftermiddagen|om\\s+ettermiddagen|eftermiddag(?:en)?|ettermiddag(?:en)?|iltapäivällä|iltapäivisin|síðdegis"), " afternoon "),
        (word("på\\s+kvällen|om\\s+aftenen|om\\s+kvelden|kväll(?:en)?|aften(?:en)?|kveld(?:en)?|illalla|um\\s+kvöldið"), " evening "),
        (word("mitt\\s+på\\s+dagen|midt\\s+på\\s+dagen|keskipäivällä|um\\s+hádegi"), " noon "),
        (word("midnatt|midnat|keskiyöllä|keskiyö|á\\s+miðnætti|miðnætti"), " midnight "),
    ]

    /// A day said as a habit: "på fredagar", "om fredagen", "på fredager", "perjantaisin", "á föstudögum".
    private static let nordicHabits: [(String, String)] = {
        let habits = [
            "på\\s+söndagar|söndagar|om\\s+søndagen|søndage|på\\s+søndager|søndager|sunnuntaisin|á\\s+sunnudögum",
            "på\\s+måndagar|måndagar|om\\s+mandagen|mandage|på\\s+mandager|mandager|maanantaisin|á\\s+mánudögum",
            "på\\s+tisdagar|tisdagar|om\\s+tirsdagen|tirsdage|på\\s+tirsdager|tirsdager|tiistaisin|á\\s+þriðjudögum",
            "på\\s+onsdagar|onsdagar|om\\s+onsdagen|onsdage|på\\s+onsdager|onsdager|keskiviikkoisin|á\\s+miðvikudögum",
            "på\\s+torsdagar|torsdagar|om\\s+torsdagen|torsdage|på\\s+torsdager|torsdager|torstaisin|á\\s+fimmtudögum",
            "på\\s+fredagar|fredagar|om\\s+fredagen|fredage|på\\s+fredager|fredager|perjantaisin|á\\s+föstudögum",
            "på\\s+lördagar|lördagar|om\\s+lørdagen|lørdage|på\\s+lørdager|lørdager|lauantaisin|á\\s+laugardögum",
        ]
        let names = [
            "söndag|søndag|sunnuntai(?:na)?|sunnudag(?:inn|ur|a)?",
            "måndag|mandag|maanantai(?:na)?|mánudag(?:inn|ur|a)?",
            "tisdag|tirsdag|tiistai(?:na)?|þriðjudag(?:inn|ur|a)?",
            "onsdag|keskiviikko(?:na)?|miðvikudag(?:inn|ur|a)?",
            "torsdag|torstai(?:na)?|fimmtudag(?:inn|ur|a)?",
            "fredag|perjantai(?:na)?|föstudag(?:inn|ur|a)?",
            "lördag|lørdag|lauantai(?:na)?|laugardag(?:inn|ur|a)?",
        ]
        let short = ["sön|søn|sun", "mån|man|mán", "tis|tir|þri", "ons|mið", "tors|tor|fim", "fre|fös", "lör|lør|lau"]
        let finnish = ["su", "ma", "ti", "ke", nil, "pe", nil]
        var rules: [(String, String)] = []
        for day in 0..<7 {
            rules.append((word(habits[day]), " every \(english[day]) "))
            rules.append((word("(?:på\\s+|á\\s+)?(?:" + names[day] + ")"), " \(english[day]) "))
            rules.append((word(short[day]) + #"\.?(?=\s|$)"#, " \(english[day]) "))
            if let two = finnish[day] {
                rules.append((word(two) + #"\.?(?=\s*\d)"#, " \(english[day]) "))
            }
        }
        return rules
    }()

    private static let nordicJoints: [(String, String)] = [
        (word("varje|hver|hvert|joka|á\\s+hverjum|hvern|hverja"), " every "),
        (word("kl\\.?|klockan|klokken|klokka|klo\\.?|kello|klukkan") + #"(?=\s*\d)"#, " at "),
        (word("en\\s+halvtimme|en\\s+halv\\s+timme|en\\s+halv\\s+time|en\\s+halvtime|hálftíma|hálfan\\s+tíma"), " half an hour "),
        (word("minuter|minutter|minuuttia|minuutin|mínútur|mínútu|mín") , " min "),
        (word("timmar|timer|tuntia|tunnin|klukkustundir|klukkustunda|klst\\.?"), " hours "),
        (word("timme|tunti|klukkustund|klukkutími|klukkutíma"), " hour "),
        (word("dagar|dage|dager|päivää|päivän|daga"), " days "),
        (word("dag|päivä|dagur|degi"), " day "),
        (word("en|ett|et|eitt|einn|eina|yhden") + #"(?=\s+(?:hour|day|half)(?![\p{L}]))"#, " a "),
        (word("om|eftir") + #"(?=\s+(?:\d|a\s|an\s|half\s))"#, " in "),
    ]
}
