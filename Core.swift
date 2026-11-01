import Foundation

enum StudyCategory: String, Codable, CaseIterable {
    case anki, chat, dictionary, materials, lesson
    var label: String { switch self {case .anki: return "Anki"; case .chat: return "ChatGPT / Codex"; case .dictionary: return "French dictionary"; case .materials: return "Édito / Materials"; case .lesson: return "Tutoring / Classes"} }
    static func ignoresIdle(_ category: StudyCategory?, keep: Bool) -> Bool {keep || category == .lesson}
    static func isZoomMeetingTitle(_ title:String)->Bool {
        // Zoom localizes its title as both "Zoom會議" and "Zoom 會議".
        // Ignore Unicode whitespace, but still require an explicit meeting label.
        let value=title.lowercased().components(separatedBy:.whitespacesAndNewlines).joined()
        return value.contains("zoommeeting") || value.contains("zoom會議") || value.contains("zoom会议") || value.contains("réunionzoom")
    }
}
struct Slice: Codable {
    var start: Date
    var end: Date
    var category: StudyCategory
}
struct Ledger: Codable {
    var device = UUID().uuidString
    var totals: [String:[String:Double]] = [:]
    var recordedThrough = Date()
    var pending: [Slice] = []
    static var calendar: Calendar { var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:"Asia/Taipei")!;c.firstWeekday=2;return c }
    static func day(_ date:Date) -> String { let p=calendar.dateComponents([.year,.month,.day],from:date);return String(format:"%04d-%02d-%02d",p.year!,p.month!,p.day!) }
    mutating func commit(_ slice:Slice) {
        var start=slice.start
        while start < slice.end {
            let next=Self.calendar.date(byAdding:.day,value:1,to:Self.calendar.startOfDay(for:start))!
            let end=min(next,slice.end)
            totals[Self.day(start),default:[:]][slice.category.rawValue,default:0] += end.timeIntervalSince(start)
            start=end
        }
    }
    mutating func add(start:Date,end:Date,category:StudyCategory?) {
        guard let category,end>start else{return}
        if let last=pending.last,last.category==category,abs(last.end.timeIntervalSince(start))<0.01 {pending[pending.count-1].end=end}
        else {pending.append(Slice(start:start,end:end,category:category))}
    }
    mutating func confirm(through cutoff:Date,dropRemainder:Bool=false) {
        var keep:[Slice]=[]
        for s in pending {
            if s.start < cutoff {commit(Slice(start:s.start,end:min(s.end,cutoff),category:s.category))}
            if !dropRemainder,s.end>cutoff {keep.append(Slice(start:max(s.start,cutoff),end:s.end,category:s.category))}
        }
        pending=keep
        recordedThrough=max(recordedThrough,cutoff)
    }
    func displayed(day:String) -> [String:Double] {
        var copy=self
        for s in pending {copy.commit(s)}
        return copy.totals[day] ?? [:]
    }
    mutating func adjust(day:String,category:StudyCategory,minutes:Int) {
        let old=totals[day]?[category.rawValue] ?? 0
        let all=(totals[day] ?? [:]).values.reduce(0,+)
        totals[day,default:[:]][category.rawValue]=min(max(0,old+Double(minutes*60)),86400-all+old)
    }
    mutating func transfer(day:String,from:StudyCategory,to:StudyCategory,minutes:Int)->Bool {
        guard from != to,minutes>0 else{return false}
        let seconds=Double(minutes*60),available=totals[day]?[from.rawValue] ?? 0
        guard seconds<=available else{return false}
        totals[day,default:[:]][from.rawValue]=available-seconds
        totals[day,default:[:]][to.rawValue,default:0]+=seconds
        return true
    }
    mutating func setGroupMinutes(day:String,lesson:Bool,minutes:Int)->Bool {
        guard (0...1440).contains(minutes) else{return false}
        let current=totals[day] ?? [:]
        let other=lesson ? current.filter{$0.key != "lesson"}.values.reduce(0,+) : current["lesson"] ?? 0
        guard Double(minutes*60)+other<=86400 else{return false}
        if lesson {totals[day,default:[:]]["lesson"]=Double(minutes*60)}
        else {
            for key in current.keys where key != "lesson" {totals[day,default:[:]][key]=0}
            totals[day,default:[:]]["chat"]=Double(minutes*60)
        }
        return true
    }
    func weekSeconds(now:Date,includePending:Bool=true)->Double {
        let start=Self.calendar.dateInterval(of:.weekOfYear,for:now)!.start
        var cursor=start,result=0.0
        while cursor<=now {let d=Self.day(cursor);result += (includePending ? displayed(day:d) : totals[d] ?? [:]).values.reduce(0,+);cursor=Self.calendar.date(byAdding:.day,value:1,to:cursor)!}
        return result
    }
    func payload(now:Date)->[String:Any] {
        let selected=totals
        let keys=selected.keys.sorted().suffix(365)
        return ["device":device,"recordedThrough":ISO8601DateFormatter().string(from:recordedThrough),"days":keys.map { day -> [String:Any] in ["day":day,"totals":Dictionary(uniqueKeysWithValues:StudyCategory.allCases.map{($0.rawValue,Int((selected[day]?[$0.rawValue] ?? 0).rounded(.down)))})] }]
    }
}

// Local-only timer. Only an explicit record action can change the ledger.
struct DraftTimer:Codable {
    var confirmed:[Slice]=[]
    var pending:[Slice]=[]
    var seconds:Double {(confirmed+pending).reduce(0){$0+max(0,$1.end.timeIntervalSince($1.start))}}
    private mutating func appendConfirmed(_ s:Slice){
        guard s.end>s.start else{return}
        if let last=confirmed.last,last.category==s.category,abs(last.end.timeIntervalSince(s.start))<0.01 {confirmed[confirmed.count-1].end=s.end}
        else {confirmed.append(s)}
    }
    mutating func add(start:Date,end:Date,category:StudyCategory?){
        guard let category,end>start else{return}
        if let last=pending.last,last.category==category,abs(last.end.timeIntervalSince(start))<0.01 {pending[pending.count-1].end=end}
        else{pending.append(Slice(start:start,end:end,category:category))}
    }
    mutating func confirm(through cutoff:Date,dropRemainder:Bool=false){
        var keep:[Slice]=[]
        for s in pending {
            if s.start<cutoff {appendConfirmed(Slice(start:s.start,end:min(s.end,cutoff),category:s.category))}
            if !dropRemainder,s.end>cutoff {keep.append(Slice(start:max(s.start,cutoff),end:s.end,category:s.category))}
        }
        pending=keep
    }
    mutating func record(into ledger:inout Ledger,as category:StudyCategory)->Double {
        let seconds=confirmed.reduce(0){$0+$1.end.timeIntervalSince($1.start)}
        for slice in confirmed {ledger.commit(Slice(start:slice.start,end:slice.end,category:category))}
        confirmed=[]
        return seconds
    }
}

func coreSelfTest() {
    let iso=ISO8601DateFormatter();let start=iso.date(from:"2026-10-31T15:55:00Z")!
    var ledger=Ledger();ledger.pending=[]
    ledger.add(start:start,end:start.addingTimeInterval(600),category:.anki)
    ledger.confirm(through:start.addingTimeInterval(600))
    precondition(ledger.totals["2026-10-31"]?["anki"]==300,"午夜前")
    precondition(ledger.totals["2026-11-01"]?["anki"]==300,"午夜後")
    var idle=Ledger();idle.pending=[]
    idle.add(start:start,end:start.addingTimeInterval(1200),category:.chat)
    idle.confirm(through:start.addingTimeInterval(300),dropRemainder:true)
    precondition(idle.pending.isEmpty)
    precondition(idle.totals.values.flatMap{$0.values}.reduce(0,+)==300,"扣除十五分鐘閒置")
    idle.add(start:start.addingTimeInterval(1800),end:start.addingTimeInterval(1860),category:.dictionary)
    idle.confirm(through:start.addingTimeInterval(1860))
    precondition(idle.totals.values.flatMap{$0.values}.reduce(0,+)==360,"回來後累加")
    let before=idle.totals
    idle.confirm(through:start.addingTimeInterval(1860))
    precondition(idle.totals==before,"重複確認不能重複計時")
    idle.adjust(day:"2026-10-31",category:.chat,minutes:-1000)
    precondition(idle.totals["2026-10-31"]?["chat"]==0)
    precondition(StudyCategory.ignoresIdle(.lesson,keep:false),"上課不因閒置暫停")
    precondition(!StudyCategory.ignoresIdle(.anki,keep:false),"一般學習保留閒置規則")
    for title in ["Zoom Meeting", "Zoom會議", "Zoom 會議", "Zoom会议", "Zoom 会议", "Zoom\u{00a0}會議", "Réunion Zoom", "Zoom 會議 - Host"] {
        precondition(StudyCategory.isZoomMeetingTitle(title),"Must recognize localized Zoom meeting title: \(title)")
    }
    for title in ["Zoom", "Zoom Workplace", "Zoom Home", "Zoom Chat"] {
        precondition(!StudyCategory.isZoomMeetingTitle(title),"Zoom home and chat must not count as meetings")
    }
    precondition(!StudyCategory.isZoomMeetingTitle("Zoom Workplace"),"僅開啟 Zoom 首頁不算上課")
    var lesson=Ledger();lesson.pending=[]
    lesson.add(start:start,end:start.addingTimeInterval(3600),category:.lesson)
    lesson.confirm(through:start.addingTimeInterval(3600))
    precondition(lesson.totals.values.flatMap{$0.values}.reduce(0,+)==3600,"完整上課一小時")
    var moved=Ledger();moved.totals=["2026-10-31":["chat":7200]]
    precondition(moved.transfer(day:"2026-10-31",from:.chat,to:.lesson,minutes:60))
    precondition(moved.totals["2026-10-31"]?["chat"]==3600 && moved.totals["2026-10-31"]?["lesson"]==3600)
    precondition(!moved.transfer(day:"2026-10-31",from:.chat,to:.lesson,minutes:61),"不得超額移轉")
    precondition(moved.totals["2026-10-31"]!.values.reduce(0,+)==7200,"移轉保持總時數")
    moved.totals=["2026-10-31":["anki":600,"chat":1200,"dictionary":300,"materials":900,"lesson":600]]
    precondition(moved.setGroupMinutes(day:"2026-10-31",lesson:false,minutes:40))
    precondition(moved.totals["2026-10-31"]!.values.reduce(0,+)==3000,"行內修改自學不得重複原分類")
    precondition(moved.setGroupMinutes(day:"2026-10-31",lesson:true,minutes:60))
    precondition(moved.totals["2026-10-31"]!.values.reduce(0,+)==6000,"兩列直接加總")
    precondition(!moved.setGroupMinutes(day:"2026-10-31",lesson:false,minutes:1440),"每日不能超過二十四小時")
    var draft=DraftTimer(),recorded=Ledger();recorded.totals=[:]
    draft.add(start:start,end:start.addingTimeInterval(1200),category:.chat)
    draft.confirm(through:start.addingTimeInterval(300),dropRemainder:true)
    precondition(draft.seconds==300 && recorded.totals.isEmpty,"自動計時不寫入正式紀錄")
    draft.add(start:start.addingTimeInterval(1800),end:start.addingTimeInterval(1860),category:.chat)
    draft.confirm(through:start.addingTimeInterval(1860))
    precondition(draft.seconds==360,"暫停後繼續累加")
    precondition(draft.record(into:&recorded,as:.lesson)==360,"只有手動確認才加入指定類別")
    precondition(draft.seconds==0,"加入紀錄後計時器歸零")
    precondition(recorded.totals.values.flatMap{$0.values}.reduce(0,+)==360)
    precondition(draft.record(into:&recorded,as:.lesson)==0,"不得重複加入")
    draft.add(start:start.addingTimeInterval(1900),end:start.addingTimeInterval(1960),category:.chat)
    draft.confirm(through:start.addingTimeInterval(1960))
    precondition(draft.seconds==60 && recorded.totals.values.flatMap{$0.values}.reduce(0,+)==360,"下一次重新計時且仍需確認")
    let emptyPayload=Ledger().payload(now:Date())["days"] as! [[String:Any]]
    precondition(emptyPayload.isEmpty,"未確認時不建立雲端日期紀錄")
    print("PASS: 午夜切分、閒置扣除、兩類行內編輯、待確認計時、暫停續算、手動加入、歸零、禁止自動寫入與重複加入")
}
