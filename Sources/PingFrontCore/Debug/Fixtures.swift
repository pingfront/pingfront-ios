#if DEBUG
    package import Foundation

    /// Offline fixture data for `-PingFrontPreview`, SwiftUI previews and snapshot tests.
    package enum PreviewFixture: String, Sendable, CaseIterable {
        case welcome
        case conversation
    }

    package enum Fixtures {
        package static let base = Date(timeIntervalSince1970: 1_793_390_400)  // 30 Oct 2026, 18:00 UTC

        package static let deniz = TeamMember(
            id: "m_deniz", name: "Deniz", role: "Maker of Clockwise", avatarURL: URL(string: "fixture://avatar/deniz"),
            timeZone: "Europe/Istanbul")
        package static let mara = TeamMember(
            id: "m_mara", name: "Mara", role: "Support", avatarURL: URL(string: "fixture://avatar/mara"), timeZone: "Europe/Berlin")
        static let ines = TeamMember(
            id: "m_ines", name: "Ines", role: "Maker of Fieldnotes", avatarURL: URL(string: "fixture://avatar/ines"),
            timeZone: "Europe/Lisbon")
        static let sam = TeamMember(
            id: "m_sam", name: "Sam", role: "Head coach at Stride", avatarURL: URL(string: "fixture://avatar/sam"),
            timeZone: "America/New_York")
        static let mara2 = TeamMember(
            id: "m_mara", name: "Mara", role: "Plant care lead", avatarURL: URL(string: "fixture://avatar/mara"), timeZone: "Europe/Berlin")
        static let theo = TeamMember(
            id: "m_theo", name: "Theo", role: "Support", avatarURL: URL(string: "fixture://avatar/theo"), timeZone: "Europe/Berlin")

        /// One example app: its name, team and the thread its team would write.
        package struct App: Sendable {
            package var id: String
            package var name: String
            package var members: [TeamMember]
            package var copy: Copy
            package var offer: OfferSlot
            /// Key of the drawn photo the person sends.
            package var photoKey: String
        }

        package static let clockwise = App(
            id: "clockwise", name: "Clockwise", members: [deniz, mara], copy: english,
            offer: OfferSlot(
                id: "yearly_winback", title: "Pro yearly", kind: .winback,
                products: [.init(id: "pro_yearly", price: "€29.99", period: "P1Y", trial: "P1M")]), photoKey: "att_widget")
        package static let fieldnotes = App(
            id: "fieldnotes", name: "Fieldnotes", members: [ines, theo],
            copy: Copy(
                role: "Maker of Fieldnotes", explanation: "Sent automatically after your 41-day streak ended",
                ping:
                    "Hi Ada, Ines here. I make Fieldnotes. Your streak ended yesterday after 41 days. Want me to pause streaks while you travel?",
                question: "Yes please. Can I export my entries before the trip?",
                ai: "You can. Open Settings, then Export, and pick Markdown or PDF. Photos are included in both.",
                extended: "Done on my side: streaks are paused until you're back.", receipt: "Streak paused until 20 Nov",
                offerTitle: "Fieldnotes Plus, 30% off", offerBody: "Unlimited journals, PDF export with photos and iCloud sync.",
                offerButton: "See the offer",
                useFor: ["Daily journal", "Travel log", "Gratitude"],
                photo: "The PDF export cuts off this page.",
                askReport: "Thanks, I see it. Could you send a report from the export screen? It attaches the log I need.",
                reportTitle: "Report the export problem", reportButton: "Report a bug", linkTitle: "Exporting with photos",
                linkButton: "Read the guide",
                timerQuestion: "Which prompt do you use most?", timers: ["Mornings", "Evenings", "Free write"],
                ratingQuestion: "How was this conversation?", reviewText: "If Fieldnotes helps you write, a review helps us a lot.",
                reviewButton: "Rate Fieldnotes",
                replyExpectation: "Usually replies within a day"),
            offer: OfferSlot(
                id: "yearly_winback", title: "Plus yearly", kind: .discount,
                products: [.init(id: "plus_yearly", price: "€24.99", period: "P1Y")]), photoKey: "att_page")
        package static let stride = App(
            id: "stride", name: "Stride", members: [sam, theo],
            copy: Copy(
                role: "Head coach at Stride", explanation: "Sent automatically after you skipped two planned runs",
                ping: "Hey Ada, Sam from Stride. You skipped two runs this week. Want a lighter plan for the next 7 days?",
                question: "Yes. My knee hurts after 5 km.",
                ai:
                    "That's worth taking seriously. Your plan now caps runs at 4 km with two extra rest days. If the pain stays, see a physio before running again.",
                extended: "I also added a free week so the lighter plan doesn't cost you anything.", receipt: "Trial extended to 21 Nov",
                offerTitle: "Stride Pro yearly, 40% off", offerBody: "Adaptive plans, injury-aware pacing and race prep.",
                offerButton: "See the offer",
                useFor: ["5K", "10K", "Half marathon"],
                photo: "This pace chart looks wrong.",
                askReport: "Thanks, that spike is a GPS glitch. Could you send a report from the run screen?",
                reportTitle: "Report the GPS glitch", reportButton: "Report a bug", linkTitle: "Running with knee pain",
                linkButton: "Read the guide",
                timerQuestion: "When do you usually run?", timers: ["Mornings", "Lunch", "Evenings"],
                ratingQuestion: "How was this conversation?", reviewText: "If Stride gets you out the door, a review helps us a lot.",
                reviewButton: "Rate Stride",
                replyExpectation: "We answer every message within a day"),
            offer: OfferSlot(
                id: "yearly_winback", title: "Pro yearly", kind: .winback,
                products: [.init(id: "pro_yearly", price: "$35.99", period: "P1Y")]), photoKey: "att_chart")
        package static let sprout = App(
            id: "sprout", name: "Sprout", members: [mara2, theo],
            copy: Copy(
                role: "Plant care lead", explanation: "Sent automatically after your fern missed two waterings",
                ping: "Hi Ada, Mara from Sprout. Your fern missed two waterings. Is the reminder time working for you?",
                question: "Not really, it rings while I'm at work.",
                ai: "You can move it: open the fern, tap Reminders and pick a time. Ferns like water every 3 to 4 days.",
                extended: "I moved all your reminders to the evening. Change them any time.", receipt: "Reminders moved to 19:00",
                offerTitle: "Sprout Plus, first month free", offerBody: "Unlimited plants, a light meter and the plant doctor.",
                offerButton: "See the offer",
                useFor: ["Indoor plants", "Balcony garden", "Herbs"],
                photo: "These leaves turned yellow this week.",
                askReport:
                    "That looks like overwatering, not a bug. If the app shows the wrong schedule, send a report from the plant screen.",
                reportTitle: "Report a wrong schedule", reportButton: "Report a bug", linkTitle: "Yellow leaves: what they mean",
                linkButton: "Read the guide",
                timerQuestion: "How much light does it get?", timers: ["Direct sun", "Bright shade", "Low light"],
                ratingQuestion: "How was this conversation?", reviewText: "If Sprout keeps your plants happy, a review helps us a lot.",
                reviewButton: "Rate Sprout",
                replyExpectation: "Usually replies in a few hours"),
            offer: OfferSlot(
                id: "yearly_winback", title: "Plus monthly", kind: .standard,
                products: [.init(id: "plus_monthly", price: "€3.99", period: "P1M", trial: "P1M")]), photoKey: "att_leaves")

        package static func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

        static let denizAuthor = Author(kind: .team, id: deniz.id, name: deniz.name, avatarURL: deniz.avatarURL)
        static let assistant = Author(kind: .ai, id: "ai", name: "Clockwise Assistant")
        static let person = Author(kind: .person, id: "p_ada", name: "Ada")
        static let system = Author(kind: .system)

        /// Team-written fixture content in one language (customer content is not translated by the SDK).
        package struct Copy: Sendable {
            var role, explanation, ping, question, ai, extended, receipt: String
            var offerTitle, offerBody, offerButton: String
            var useFor: [String]
            var photo, askReport, reportTitle, reportButton, linkTitle, linkButton, timerQuestion: String
            var timers: [String]
            var ratingQuestion, reviewText, reviewButton: String
            var replyExpectation = "Usually replies in a few hours"
        }

        /// A message type this SDK does not know (for the dedicated "unknown content" state).
        ///
        /// A team message with links, and a link-only message from the person.
        package static let linkMessages: [Message] = [
            Message(
                id: "msg_link_1", seq: 20, author: denizAuthor,
                parts: [.text("The widget guide is at https://clockwise.app/help/widgets, with a video at the end.")], createdAt: at(18)),
            Message(
                id: "msg_link_2", seq: 21, author: Author(kind: .person), parts: [.text("https://clockwise.app/pricing")],
                createdAt: at(18.5)),
        ]

        /// A saved link to a screen of the app (with a web fallback for builds that don't register it), and a web link.
        package static let screenLinkMessages: [Message] = [
            Message(
                id: "msg_screen_1", seq: 22, author: denizAuthor,
                parts: [
                    .text("You can pick a gentler tone here."),
                    .card(
                        CardPart(
                            card: .link(
                                LinkCard(
                                    id: "card_link_screen", title: "Change the alarm sound", url: "https://clockwise.example/help/sounds",
                                    button: "Open sound settings", screen: LinkScreen(id: "settings.sound", params: ["tab": "tones"]))))),
                    .card(
                        CardPart(
                            card: .link(
                                LinkCard(
                                    id: "card_link_web", title: "How alarms work", url: "https://clockwise.example/help/alarms",
                                    button: "Read the guide")))),
                ],
                createdAt: at(19))
        ]

        /// A failed payment: Apple's billing sheet from a store action card, then the local receipt.
        package static let storeActionMessages: [Message] = [
            Message(
                id: "msg_store_1", seq: 24, author: denizAuthor,
                parts: [
                    .text("Your Pro renewal didn't go through. Updating the payment method keeps your alarms and sounds."),
                    .card(
                        CardPart(
                            card: .storeAction(
                                StoreActionCard(id: "card_store_billing", action: .billingIssue, subscriptionGroupId: "21000001")))),
                ],
                createdAt: at(19)),
            Message(
                id: "msg_store_2", seq: 25, author: denizAuthor,
                parts: [.card(CardPart(card: .storeAction(StoreActionCard(id: "card_store_restore", action: .restorePurchases))))],
                createdAt: at(19.2)),
            Message(
                id: "msg_store_3", seq: 25, author: Author(kind: .system),
                parts: [.receipt(ReceiptPart(action: .custom, text: "Payment method updated"))], createdAt: at(19.4)),
        ]

        /// The team offers the subscription settings: Apple's manage subscriptions sheet from a store action card.
        package static let manageSubscriptionMessages: [Message] = [
            Message(
                id: "msg_manage_1", seq: 24, author: denizAuthor,
                parts: [
                    .text("You can switch to yearly or turn off renewal from your subscription settings."),
                    .card(
                        CardPart(
                            card: .storeAction(
                                StoreActionCard(id: "card_store_manage", action: .manageSubscriptions, subscriptionGroupId: "21000001")))),
                ],
                createdAt: at(19))
        ]

        /// The AI teammate answers, the person asks for a person, and it hands the conversation to the team: the
        /// hand-off line has no check, since nothing was done for the person.
        package static let aiHandoffMessages: [Message] = [
            Message(
                id: "msg_handoff_1", seq: 28, author: assistant,
                parts: [.text("Smart wake follows the iPhone's motion, so put the phone on the mattress, not the nightstand.")],
                createdAt: at(20)),
            Message(
                id: "msg_handoff_2", seq: 29, author: Author(kind: .person), parts: [.text("I'd rather ask a person, please.")],
                createdAt: at(20.5)),
            Message(
                id: "msg_handoff_3", seq: 30, author: Author(kind: .system),
                parts: [.receipt(ReceiptPart(action: .handedOff, text: "Deniz will reply"))], createdAt: at(20.6)),
        ]

        /// Photos the app's retention deleted (`removed: true`, no url): one alone, then two in a grid.
        package static let removedPhotoMessages: [Message] = [
            Message(
                id: "msg_removed_1", seq: 26, author: Author(kind: .person),
                parts: [.image(ImagePart(attachmentId: "att_removed_1", width: 1170, height: 2532, removed: true))],
                createdAt: at(19)),
            Message(
                id: "msg_removed_2", seq: 27, author: denizAuthor,
                parts: [
                    .image(ImagePart(attachmentId: "att_removed_2", width: 1170, height: 1560, removed: true)),
                    .image(ImagePart(attachmentId: "att_removed_3", width: 1170, height: 1560, removed: true)),
                    .text("Here is how the alarm screen looked."),
                ],
                createdAt: at(19.5)),
        ]

        /// Two offers: the newer one replaces the older one.
        package static let offerMessages: [Message] = [
            Message(
                id: "msg_offer_old", seq: 22, author: denizAuthor,
                parts: [
                    .card(
                        CardPart(
                            card: .offer(
                                OfferCard(
                                    id: "card_offer_old", offerId: "pro_yearly", title: "Pro yearly, 20% off", button: "See the offer"))))
                ],
                createdAt: at(19)),
            Message(
                id: "msg_offer_new", seq: 23, author: denizAuthor,
                parts: [
                    .card(
                        CardPart(
                            card: .offer(
                                OfferCard(
                                    id: "card_offer_new", offerId: "pro_monthly", title: "Pro monthly",
                                    body: "Everything in Pro, month to month.", button: "See the offer"))))
                ],
                createdAt: at(19.5)),
        ]

        package static let unknownMessage = Message(
            id: "msg_unknown", seq: 14, author: denizAuthor,
            parts: [.unknown(type: "poll")], createdAt: at(17.5))

        package static let english = Copy(
            role: "Maker of Clockwise", explanation: "Sent automatically after you closed Plans twice",
            ping: "Hi Ada, I'm Deniz. I make Clockwise. You closed the plans screen twice today. Anything unclear about Pro?",
            question: "Is the yearly plan refundable if I change my mind?",
            ai: "Yes. Apple refunds yearly plans bought in the last 14 days. Open Settings, tap your name, then Media & Purchases.",
            extended: "Adding to that: I extended your trial so you can try widgets first.", receipt: "Trial extended to 14 Nov",
            offerTitle: "Pro yearly, first month free", offerBody: "Widgets, unlimited timers and sync across your devices.",
            offerButton: "See the offer",
            useFor: ["Work focus", "Workouts", "Cooking"],
            photo: "Here is the widget glitch I mentioned.",
            askReport: "Thanks, I can see it. Could you send a report from the widget screen? It includes the logs I need.",
            reportTitle: "Report the widget glitch", reportButton: "Report a bug", linkTitle: "How widgets refresh",
            linkButton: "Read the guide",
            timerQuestion: "Which timer do you start most?", timers: ["Pomodoro", "Countdown", "Lap timer"],
            ratingQuestion: "How was this conversation?", reviewText: "If Clockwise helps your day, a review helps us a lot.",
            reviewButton: "Rate Clockwise")

        package static let copies: [String: Copy] = [
            "en": english,
            "de": Copy(
                role: "Entwickler von Clockwise", explanation: "Automatisch gesendet, nachdem du die Tarife zweimal geschlossen hast",
                ping:
                    "Hallo Ada, ich bin Deniz und entwickle Clockwise. Du hast die Tarifübersicht heute zweimal geschlossen. Ist bei Pro etwas unklar?",
                question: "Kann ich das Jahresabo zurückgeben, wenn ich es mir anders überlege?",
                ai:
                    "Ja. Apple erstattet Jahresabos innerhalb von 14 Tagen nach dem Kauf. Öffne Einstellungen, tippe auf deinen Namen und dann auf Medien & Käufe.",
                extended: "Noch dazu: Ich habe deinen Testzeitraum verlängert, damit du zuerst die Widgets ausprobieren kannst.",
                receipt: "Testzeitraum bis 14. Nov. verlängert",
                offerTitle: "Pro jährlich, erster Monat kostenlos",
                offerBody: "Widgets, unbegrenzte Timer und Synchronisierung auf allen Geräten.", offerButton: "Angebot ansehen",
                useFor: ["Konzentriertes Arbeiten", "Training", "Kochen"],
                photo: "Hier ist der Widget-Fehler, von dem ich erzählt habe.",
                askReport:
                    "Danke, ich sehe ihn. Kannst du vom Widget-Bildschirm aus einen Bericht senden? Er enthält die Logs, die ich brauche.",
                reportTitle: "Widget-Fehler melden", reportButton: "Fehler melden", linkTitle: "Wie sich Widgets aktualisieren",
                linkButton: "Anleitung lesen",
                timerQuestion: "Welchen Timer startest du am häufigsten?", timers: ["Pomodoro", "Countdown", "Rundenzeit"],
                ratingQuestion: "Wie war dieses Gespräch?",
                reviewText: "Wenn Clockwise dir im Alltag hilft, hilft uns eine Bewertung sehr.", reviewButton: "Clockwise bewerten",
                replyExpectation: "Antwortet meist innerhalb weniger Stunden"),
            "ja": Copy(
                role: "Clockwise開発者", explanation: "プラン画面を2回閉じた後に自動で送信されました",
                ping: "こんにちは、Adaさん。Clockwiseを作っているDenizです。今日プラン画面を2回閉じていましたね。Proについてわかりにくい点はありますか？",
                question: "気が変わったら年間プランは返金できますか？",
                ai: "はい。購入から14日以内の年間プランはAppleが返金します。設定を開いて名前をタップし、「メディアと購入」を選んでください。",
                extended: "補足すると、ウィジェットを先に試せるよう体験期間を延長しました。", receipt: "体験期間を11月14日まで延長しました",
                offerTitle: "Pro年間プラン、最初の1か月無料", offerBody: "ウィジェット、無制限のタイマー、すべてのデバイスで同期。", offerButton: "オファーを見る",
                useFor: ["仕事の集中", "トレーニング", "料理"],
                photo: "お話ししたウィジェットの不具合です。",
                askReport: "ありがとうございます、確認できました。ウィジェット画面から報告を送ってもらえますか？必要なログが含まれます。",
                reportTitle: "ウィジェットの不具合を報告", reportButton: "不具合を報告", linkTitle: "ウィジェットの更新のしくみ", linkButton: "ガイドを読む",
                timerQuestion: "いちばんよく使うタイマーはどれですか？", timers: ["ポモドーロ", "カウントダウン", "ラップタイマー"],
                ratingQuestion: "今回のやり取りはいかがでしたか？", reviewText: "Clockwiseが役に立っていたら、レビューをいただけるととても助かります。", reviewButton: "Clockwiseを評価",
                replyExpectation: "通常は数時間以内に返信します"),
            "ar": Copy(
                role: "صانع Clockwise", explanation: "أُرسلت تلقائيًا بعد أن أغلقت صفحة الخطط مرتين",
                ping: "مرحبًا آدا، أنا دنيز وأصنع Clockwise. أغلقتِ صفحة الخطط مرتين اليوم. هل هناك ما هو غير واضح في Pro؟",
                question: "هل يمكن استرداد ثمن الخطة السنوية إذا غيّرت رأيي؟",
                ai: "نعم. تسترد Apple الخطط السنوية المشتراة خلال آخر 14 يومًا. افتح الإعدادات، واضغط على اسمك، ثم الوسائط والمشتريات.",
                extended: "إضافة إلى ذلك: مددتُ فترتك التجريبية لتجربي الأدوات أولًا.", receipt: "مُددت الفترة التجريبية حتى 14 نوفمبر",
                offerTitle: "Pro السنوي، الشهر الأول مجانًا", offerBody: "أدوات، ومؤقتات غير محدودة، ومزامنة بين أجهزتك.",
                offerButton: "عرض العرض",
                useFor: ["التركيز في العمل", "التمارين", "الطبخ"],
                photo: "هذا هو خلل الأداة الذي ذكرته.",
                askReport: "شكرًا، أراه الآن. هل يمكنك إرسال بلاغ من شاشة الأداة؟ فهو يتضمن السجلات التي أحتاجها.",
                reportTitle: "الإبلاغ عن خلل الأداة", reportButton: "الإبلاغ عن خطأ", linkTitle: "كيف تتحدث الأدوات",
                linkButton: "قراءة الدليل",
                timerQuestion: "أي مؤقت تستخدمين أكثر؟", timers: ["بومودورو", "عد تنازلي", "مؤقت اللفات"],
                ratingQuestion: "كيف كانت هذه المحادثة؟", reviewText: "إذا كان Clockwise يساعدك في يومك، فتقييمك يساعدنا كثيرًا.",
                reviewButton: "قيّم Clockwise", replyExpectation: "يرد عادةً خلال بضع ساعات"),
            "tr": Copy(
                role: "Clockwise'ın geliştiricisi", explanation: "Planlar ekranını iki kez kapattıktan sonra otomatik gönderildi",
                ping:
                    "Merhaba Ada, ben Deniz. Clockwise'ı ben yapıyorum. Bugün planlar ekranını iki kez kapattın. Pro ile ilgili net olmayan bir şey var mı?",
                question: "Fikrimi değiştirirsem yıllık planın parasını geri alabilir miyim?",
                ai:
                    "Evet. Apple son 14 gün içinde alınan yıllık planları iade eder. Ayarlar'ı aç, adına dokun, sonra Medya ve Satın Alımlar'a gir.",
                extended: "Ek olarak: Önce widget'ları deneyebilmen için deneme süreni uzattım.",
                receipt: "Deneme süresi 14 Kasım'a uzatıldı",
                offerTitle: "Pro yıllık, ilk ay ücretsiz", offerBody: "Widget'lar, sınırsız zamanlayıcı ve tüm cihazlarında eşitleme.",
                offerButton: "Teklife bak",
                useFor: ["İşe odaklanma", "Antrenman", "Yemek"],
                photo: "Bahsettiğim widget hatası bu.",
                askReport: "Teşekkürler, görüyorum. Widget ekranından bir rapor gönderebilir misin? İhtiyacım olan kayıtlar raporda olur.",
                reportTitle: "Widget hatasını bildir", reportButton: "Hata bildir", linkTitle: "Widget'lar nasıl yenilenir",
                linkButton: "Rehberi oku",
                timerQuestion: "En çok hangi zamanlayıcıyı başlatıyorsun?", timers: ["Pomodoro", "Geri sayım", "Tur sayacı"],
                ratingQuestion: "Bu sohbet nasıldı?", reviewText: "Clockwise gününe yardımcı oluyorsa, bir yorum bize çok yardımcı olur.",
                reviewButton: "Clockwise'ı değerlendir", replyExpectation: "Genellikle birkaç saat içinde yanıt verir"),
            "fa": Copy(
                role: "سازندهٔ Clockwise", explanation: "پس از اینکه صفحهٔ طرح‌ها را دو بار بستید، خودکار ارسال شد",
                ping:
                    "سلام Ada، من Deniz هستم و Clockwise را می‌سازم. امروز دو بار صفحهٔ طرح‌ها را بستید. چیزی دربارهٔ Pro برایتان مبهم است؟",
                question: "اگر نظرم عوض شود، پول طرح سالانه را پس می‌گیرم؟",
                ai:
                    "بله. Apple هزینهٔ طرح‌های سالانه‌ای را که در ۱۴ روز گذشته خریده شده‌اند برمی‌گرداند. تنظیمات را باز کنید، روی نامتان بزنید و بعد «رسانه و خریدها» را انتخاب کنید.",
                extended: "یک نکته هم اضافه کنم: دورهٔ آزمایشی‌تان را تمدید کردم تا اول ویجت‌ها را امتحان کنید.",
                receipt: "دورهٔ آزمایشی تا ۱۴ نوامبر تمدید شد",
                offerTitle: "Pro سالانه، ماه اول رایگان", offerBody: "ویجت‌ها، تایمرهای نامحدود و همگام‌سازی بین همهٔ دستگاه‌هایتان.",
                offerButton: "دیدن پیشنهاد",
                useFor: ["تمرکز در کار", "ورزش", "آشپزی"],
                photo: "این همان مشکل ویجت است که گفتم.",
                askReport: "ممنون، می‌بینمش. می‌شود از صفحهٔ ویجت یک گزارش بفرستید؟ لاگ‌هایی که لازم دارم در آن هست.",
                reportTitle: "گزارش مشکل ویجت", reportButton: "گزارش اشکال", linkTitle: "ویجت‌ها چطور به‌روز می‌شوند",
                linkButton: "خواندن راهنما",
                timerQuestion: "کدام تایمر را بیشتر از همه روشن می‌کنید؟", timers: ["پومودورو", "شمارش معکوس", "زمان‌سنج دور"],
                ratingQuestion: "این گفتگو چطور بود؟", reviewText: "اگر Clockwise به روزتان کمک می‌کند، نوشتن یک نظر خیلی به ما کمک می‌کند.",
                reviewButton: "امتیاز دادن به Clockwise", replyExpectation: "معمولاً ظرف چند ساعت پاسخ می‌دهد"),
            "cs": Copy(
                role: "Vývojář Clockwise", explanation: "Odesláno automaticky poté, co jsi dvakrát zavřela přehled tarifů",
                ping:
                    "Ahoj Ado, jsem Deniz a dělám Clockwise. Dnes jsi dvakrát zavřela přehled tarifů. Není ti u Pro něco jasné?",
                question: "Dostanu za roční předplatné peníze zpátky, když si to rozmyslím?",
                ai:
                    "Ano. Apple vrací peníze za roční předplatné koupené v posledních 14 dnech. Otevři Nastavení, klepni na své jméno a pak na Média a nákupy.",
                extended: "A ještě: zkušební období máš prodloužené, abys mohla nejdřív vyzkoušet widgety.",
                receipt: "Zkušební období prodlouženo do 14. listopadu",
                offerTitle: "Pro na rok, první měsíc zdarma",
                offerBody: "Widgety, neomezené časovače a synchronizace na všech tvých zařízeních.", offerButton: "Zobrazit nabídku",
                useFor: ["Soustředěná práce", "Cvičení", "Vaření"],
                photo: "Tady je ta chyba widgetu, o které jsem psala.",
                askReport:
                    "Díky, vidím ji. Můžeš poslat hlášení z obrazovky widgetu? Obsahuje logy, které potřebuju.",
                reportTitle: "Nahlásit chybu widgetu", reportButton: "Nahlásit chybu", linkTitle: "Jak se widgety obnovují",
                linkButton: "Přečíst návod",
                timerQuestion: "Který časovač spouštíš nejčastěji?", timers: ["Pomodoro", "Odpočet", "Mezičasy"],
                ratingQuestion: "Jaká byla tahle konverzace?",
                reviewText: "Jestli ti Clockwise pomáhá během dne, hodnocení nám hodně pomůže.", reviewButton: "Ohodnotit Clockwise",
                replyExpectation: "Obvykle odpovídá do několika hodin"),
            "ta": Copy(
                role: "Clockwise உருவாக்குநர்", explanation: "நீங்கள் திட்டங்கள் திரையை இரண்டு முறை மூடிய பிறகு தானாக அனுப்பப்பட்டது",
                ping:
                    "வணக்கம் Ada, நான் Deniz. Clockwise-ஐ நான்தான் உருவாக்குகிறேன். இன்று திட்டங்கள் திரையை இரண்டு முறை மூடினீர்கள். Pro பற்றி ஏதாவது புரியவில்லையா?",
                question: "மனம் மாறினால் ஆண்டுத் திட்டத்துக்குப் பணம் திரும்பக் கிடைக்குமா?",
                ai:
                    "ஆம். கடந்த 14 நாட்களில் வாங்கிய ஆண்டுத் திட்டங்களுக்கு Apple பணத்தைத் திருப்பித் தரும். அமைப்புகளைத் திறந்து, உங்கள் பெயரைத் தட்டி, பிறகு மீடியா & வாங்குதல்கள் என்பதைத் தட்டுங்கள்.",
                extended: "கூடுதலாக: முதலில் விட்ஜெட்களை முயற்சிக்க உங்கள் சோதனைக் காலத்தை நீட்டித்துள்ளேன்.",
                receipt: "சோதனைக் காலம் நவம்பர் 14 வரை நீட்டிக்கப்பட்டது",
                offerTitle: "Pro ஆண்டுத் திட்டம், முதல் மாதம் இலவசம்",
                offerBody: "விட்ஜெட்கள், வரம்பற்ற டைமர்கள், உங்கள் எல்லாச் சாதனங்களிலும் ஒத்திசைவு.", offerButton: "சலுகையைப் பார்க்கவும்",
                useFor: ["வேலையில் கவனம்", "உடற்பயிற்சி", "சமையல்"],
                photo: "நான் சொன்ன விட்ஜெட் கோளாறு இதுதான்.",
                askReport:
                    "நன்றி, எனக்குத் தெரிகிறது. விட்ஜெட் திரையிலிருந்து ஒரு அறிக்கையை அனுப்ப முடியுமா? எனக்குத் தேவையான பதிவுகள் அதில் இருக்கும்.",
                reportTitle: "விட்ஜெட் கோளாறைப் புகாரளிக்கவும்", reportButton: "பிழையைப் புகாரளிக்கவும்",
                linkTitle: "விட்ஜெட்கள் எப்படிப் புதுப்பிக்கப்படுகின்றன", linkButton: "வழிகாட்டியைப் படிக்கவும்",
                timerQuestion: "எந்த டைமரை அதிகமாகத் தொடங்குகிறீர்கள்?", timers: ["பொமோடோரோ", "கவுன்ட்டவுன்", "லேப் டைமர்"],
                ratingQuestion: "இந்த உரையாடல் எப்படி இருந்தது?",
                reviewText: "Clockwise உங்கள் நாளுக்கு உதவினால், ஒரு மதிப்பாய்வு எங்களுக்கு மிகவும் உதவும்.",
                reviewButton: "Clockwise-ஐ மதிப்பிடுங்கள்", replyExpectation: "வழக்கமாகச் சில மணிநேரத்தில் பதில் கிடைக்கும்"),
        ]

        /// A thread that shows every part type, in a language.
        package static func messages(_ copy: Copy = english, app: App = clockwise) -> [Message] {
            let lead = app.members[0]
            let deniz = Author(kind: .team, id: lead.id, name: lead.name, avatarURL: lead.avatarURL)
            let assistant = Author(kind: .ai, id: "ai", name: "\(app.name) Assistant")
            return [
                Message(
                    id: "msg_1", seq: 1, author: deniz, parts: [.text(copy.ping)], createdAt: at(0),
                    ping: PingOrigin(kind: .play, playId: "play_plans", explanation: copy.explanation)),
                Message(
                    id: "msg_2", seq: 2, clientId: "6f1d6c2e-2f43-4f7e-9a4b-0d7a3f1c0001", author: person, parts: [.text(copy.question)],
                    createdAt: at(4)),
                Message(id: "msg_3", seq: 3, author: assistant, parts: [.text(copy.ai)], createdAt: at(4.5)),
                Message(id: "msg_4", seq: 4, author: deniz, parts: [.text(copy.extended)], createdAt: at(9)),
                Message(
                    id: "msg_5", seq: 5, author: system, parts: [.receipt(ReceiptPart(action: .trialExtended, text: copy.receipt))],
                    createdAt: at(9.2)),
                Message(
                    id: "msg_6", seq: 6, author: deniz,
                    parts: [
                        .card(
                            CardPart(
                                card: .offer(
                                    OfferCard(
                                        id: "card_offer", offerId: "yearly_winback", title: copy.offerTitle, body: copy.offerBody,
                                        button: copy.offerButton))))
                    ], createdAt: at(9.4)),
                Message(
                    id: "msg_7", seq: 7, author: deniz,
                    parts: [
                        .card(
                            CardPart(
                                card: .choices(
                                    ChoicesCard(
                                        id: "card_choice_1",
                                        options: zip(["work", "sport", "cook"], copy.useFor).map { .init(id: $0, label: $1) })),
                                result: CardResult(at: at(11), answer: .choice(id: "work"))))
                    ], createdAt: at(10)),
                Message(
                    id: "msg_8", seq: 8, clientId: "6f1d6c2e-2f43-4f7e-9a4b-0d7a3f1c0002", author: person,
                    parts: [
                        .image(
                            ImagePart(
                                attachmentId: app.photoKey, width: 1170, height: 1400, url: URL(string: "fixture://image/\(app.photoKey)"))),
                        .text(copy.photo),
                    ], createdAt: at(14)),
                Message(
                    id: "msg_9", seq: 9, author: deniz,
                    parts: [
                        .text(copy.askReport),
                        .card(CardPart(card: .report(ReportCard(id: "card_report", title: copy.reportTitle, button: copy.reportButton)))),
                    ], createdAt: at(16)),
                Message(
                    id: "msg_10", seq: 10, author: deniz,
                    parts: [
                        .card(
                            CardPart(
                                card: .link(
                                    LinkCard(
                                        id: "card_link", title: copy.linkTitle, url: "https://\(app.id).app/help", button: copy.linkButton))
                            ))
                    ], createdAt: at(16.5)),
                Message(
                    id: "msg_11", seq: 11, author: deniz,
                    parts: [
                        .text(copy.timerQuestion),
                        .card(
                            CardPart(
                                card: .choices(
                                    ChoicesCard(
                                        id: "card_choice_2",
                                        options: zip(["pomo", "count", "lap"], copy.timers).map { .init(id: $0, label: $1) })))),
                    ], createdAt: at(17)),
                Message(
                    id: "msg_12", seq: 12, author: deniz,
                    parts: [.card(CardPart(card: .rating(RatingCard(id: "card_rating", question: copy.ratingQuestion, scale: 5))))],
                    createdAt: at(17.2)),
                Message(
                    id: "msg_13", seq: 13, author: deniz,
                    parts: [
                        .text(copy.reviewText),
                        .card(
                            CardPart(
                                card: .review(
                                    ReviewCard(
                                        id: "card_review", mode: .nativePrompt,
                                        storeURL: URL(string: "https://apps.apple.com/app/id000000"), button: copy.reviewButton)))),
                    ], createdAt: at(17.4)),
            ]
        }

        /// The team with a localized role.
        package static func team(_ copy: Copy, app: App = clockwise) -> [TeamMember] {
            var members = app.members
            members[0].role = copy.role
            return members
        }

        package static func config(look: ChatLook = ChatLook(), draft: Bool = false, revision: Int = 3, app: App = clockwise) -> AppConfig {
            AppConfig(
                revision: revision, draft: draft, appName: app.name, look: look, team: app.members,
                features: .init(photos: true, reports: true, translation: false, ai: true), liveUrl: nil)
        }

        /// The example app each look variant belongs to.
        package static func app(forVariant name: String) -> App {
            switch name {
            case "variant-a": fieldnotes
            case "variant-b": stride
            case "variant-c": sprout
            default: clockwise
            }
        }

        /// Fieldnotes: serif, square, compact, team header, green accent.
        package static var variantA: ChatLook {
            var look = ChatLook()
            look.theme.font = .serif
            look.theme.corners = .square
            look.theme.density = .compact
            look.theme.accent = PingFrontColor(light: "#1F6F5C", dark: "#5CC8A8")
            look.theme.teamBubble = PingFrontColor(light: "#EEF1EC", dark: "#22302B")
            look.header.style = .team
            look.header.title = LocalizedText(["default": "The Fieldnotes team", "de": "Das Fieldnotes-Team"])
            look.welcome.title = LocalizedText(["default": "Write to the people who make Fieldnotes"])
            look.topics = [
                .init(id: "billing", label: LocalizedText(["default": "Billing"]), symbol: .billing, prefill: nil),
                .init(
                    id: "export", label: LocalizedText(["default": "Export problem"]), symbol: .bug,
                    prefill: LocalizedText(["default": "My export stopped working when "])),
                .init(id: "idea", label: LocalizedText(["default": "Feature idea"]), symbol: .idea, prefill: nil),
                .init(id: "privacy", label: LocalizedText(["default": "My data"]), symbol: .privacy, prefill: nil),
            ]
            look.messages.timestamps = .always
            return look
        }

        /// Stride: rounded, soft, app-icon header, dark scheme, orange accent.
        package static var variantB: ChatLook {
            var look = ChatLook()
            look.theme.font = .rounded
            look.theme.corners = .soft
            look.theme.scheme = .dark
            look.theme.accent = PingFrontColor(light: "#E8590C", dark: "#FF8A3D")
            look.theme.background = PingFrontColor(light: "#FFFFFF", dark: "#17171C")
            look.theme.teamBubble = PingFrontColor(light: "#F1F1F4", dark: "#26262E")
            look.header.style = .app
            look.header.showLocalTime = false
            look.messages.showAvatars = false
            look.replyExpectation = LocalizedText(["default": "We answer every message within a day"])
            look.aiName = "Coach"
            return look
        }

        /// Sprout: a pale yellow custom accent (text picked by contrast), person header for Mara, photos off.
        package static var variantC: ChatLook {
            var look = ChatLook()
            look.theme.accent = PingFrontColor(light: "#FFE066", dark: "#FFE066")
            look.theme.teamBubble = PingFrontColor(light: "#C9D2E0", dark: "#33405F")
            look.header.memberId = "m_mara"
            look.composer.photos = false
            look.composer.placeholder = LocalizedText(["default": "Ask Mara about your plants"])
            look.topics = [
                .init(id: "plants", label: LocalizedText(["default": "Plant care"]), symbol: .question, prefill: nil),
                .init(id: "restore", label: LocalizedText(["default": "Restore Plus"]), symbol: .restore, prefill: nil),
                .init(id: "bug", label: LocalizedText(["default": "Report a bug"]), symbol: .bug, prefill: nil),
                .init(id: "gift", label: LocalizedText(["default": "Gift Sprout"]), symbol: .gift, prefill: nil),
            ]
            return look
        }
    }

    extension PingFront {
        /// A standalone instance for previews and snapshots (no engine, no network).
        package static func preview(
            _ fixture: PreviewFixture, look: ChatLook = ChatLook(), draft: Bool = false, host: HostAppInfo? = nil,
            appearance: ChatAppearance = ChatAppearance(), language: String = "en", app: Fixtures.App = Fixtures.clockwise
        ) -> PingFront {
            let instance = PingFront()
            instance.configuration.appearance = appearance
            if let host { instance.registry.host = host }
            instance.previewConfig = Fixtures.config(look: look, draft: draft, app: app)
            instance.loadPreview(fixture, language: language, app: app)
            return instance
        }

        package func loadPreview(_ fixture: PreviewFixture, language: String = "en", app: Fixtures.App = Fixtures.clockwise) {
            let copy = app.id == "clockwise" ? (Fixtures.copies[language] ?? Fixtures.english) : app.copy
            offerSlots = [app.offer]
            conversation.team = Fixtures.team(copy, app: app)
            conversation.replyExpectation = copy.replyExpectation
            conversation.phase = .ready
            switch fixture {
            case .welcome:
                conversation.messages = []
            case .conversation:
                conversation.messages = Fixtures.messages(copy, app: app)
                conversation.teamReadSeq = 8
            }
            isTestDevice = previewConfig?.draft ?? false
            refreshLook()
        }

        /// Overrides for preview states.
        package func setPreviewProblem(_ problem: ConfigurationProblem?) { configurationProblem = problem }

        /// Store action cards render as with the StoreKit module (in-app buttons) in previews.
        package func setPreviewStoreActions() { registry.storeActionHandler = PreviewStoreActions() }
    }

    /// A store action handler that does nothing, for previews and snapshots.
    @MainActor final class PreviewStoreActions: StoreActionHandling {
        func perform(_ request: StoreActionRequest) async -> StoreActionOutcome { .cancelled }
    }

    extension Engine {
        func enterPreview(_ fixture: PreviewFixture) {
            preview = true
            facade.previewConfig = Fixtures.config()
            facade.loadPreview(fixture)
        }
    }
#endif
