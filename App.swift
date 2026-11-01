import AppKit
import SwiftUI
import ApplicationServices
import Security

let service="org.frenchstudytracker.app.cloud"
let supportURL=URL(fileURLWithPath:ProcessInfo.processInfo.environment["FRENCH_TIMER_DATA"] ?? NSHomeDirectory()+"/Library/Application Support/FrenchStudyTimer",isDirectory:true)

struct CloudConfig:Codable {var url:String}
struct TimerSnapshot:Codable {var ledger:Ledger;var draft:DraftTimer}
func tokenRead(interactive:Bool=false)->String? {
    let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"site",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne,kSecUseAuthenticationUI as String:interactive ? kSecUseAuthenticationUIAllow:kSecUseAuthenticationUIFail]
    var item:CFTypeRef?;guard SecItemCopyMatching(query as CFDictionary,&item)==errSecSuccess,let data=item as? Data else{return nil};return String(data:data,encoding:.utf8)
}
func tokenSave(_ token:String)throws {
    let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"site"]
    let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:Data(token.utf8)] as CFDictionary)
    if status==errSecItemNotFound {var item=q;item[kSecValueData as String]=Data(token.utf8);guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else{throw NSError(domain:"Keychain",code:1)}}
    else if status != errSecSuccess {throw NSError(domain:"Keychain",code:Int(status))}
}
func dataSave<T:Encodable>(_ value:T,to name:String)throws {
    try FileManager.default.createDirectory(at:supportURL,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let url=supportURL.appendingPathComponent(name)
    try JSONEncoder().encode(value).write(to:url,options:.atomic)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
}

final class StudyModel:ObservableObject {
    @Published var status="Waiting for French study"
    @Published var today:[String:Double]=[:]
    @Published var week=0.0
    @Published var syncing="Not synced yet"
    @Published var manual=false
    @Published var paused=false
    @Published var ended=false
    @Published var keep=false
    @Published var chatStudy=false
    @Published var zoomLessons=true
    @Published var selected=StudyCategory.chat
    @Published var correctionMessage=""
    @Published var trusted=AXIsProcessTrusted()
    @Published var draftSeconds=0.0
    @Published var recordMessage=""
    var ledger:Ledger
    var draft:DraftTimer
    var testing=false
    var testIdle=0.0
    var testCategory:StudyCategory?
    var testZoomTitle:String?
    var lastExplicitActivity=Date.distantPast
    var previous=Date()
    var previousCategory:StudyCategory?
    var lastAutoCategory:StudyCategory?
    var rearm=false
    var sleeping=false
    var lastSync=Date.distantPast
    var lastSave=Date.distantPast
    var inFlight=false
    var cachedCloudToken:String?
    var ankiCategory:StudyCategory?
    var lastAnkiCheck=Date.distantPast
    var lastAnkiCard=Date.distantPast
    var ankiBusy=false
    var ticker:Timer?
    var onTitle:((String)->Void)?
    let config:CloudConfig?
    init(testing:Bool=false){
        self.testing=testing
        if testing {ledger=Ledger();draft=DraftTimer();config=nil;return}
        if let data=try? Data(contentsOf:supportURL.appendingPathComponent("ledger.json")),let stored=try? JSONDecoder().decode(Ledger.self,from:data){ledger=stored}else{ledger=Ledger()}
        if let data=try? Data(contentsOf:supportURL.appendingPathComponent("draft.json")),let stored=try? JSONDecoder().decode(DraftTimer.self,from:data){draft=stored;draft.pending=[]}else{draft=DraftTimer()}
        if let data=try? Data(contentsOf:supportURL.appendingPathComponent("snapshot.json")),let stored=try? JSONDecoder().decode(TimerSnapshot.self,from:data){ledger=stored.ledger;draft=stored.draft;draft.pending=[]}
        // Previous versions' unconfirmed time is retained locally, never auto-recorded.
        draft.pending.append(contentsOf:ledger.pending);ledger.pending=[]
        config=(try? Data(contentsOf:supportURL.appendingPathComponent("cloud.json"))).flatMap{try? JSONDecoder().decode(CloudConfig.self,from:$0)}
        let c=NSWorkspace.shared.notificationCenter
        c.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main){[weak self]_ in self?.sleep()}
        c.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self]_ in self?.wake()}
        c.addObserver(forName:NSWorkspace.sessionDidResignActiveNotification,object:nil,queue:.main){[weak self]_ in self?.sleep()}
        c.addObserver(forName:NSWorkspace.sessionDidBecomeActiveNotification,object:nil,queue:.main){[weak self]_ in self?.wake()}
        ticker=Timer(timeInterval:1,repeats:true){[weak self]_ in self?.tick()}
        RunLoop.main.add(ticker!,forMode:.common)
        tick()
    }
    func idle()->Double {testing ? testIdle:CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.null)}
    func title(of app:NSRunningApplication)->String {
        guard trusted else{return ""}
        let element=AXUIElementCreateApplication(app.processIdentifier);var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXFocusedWindowAttribute as CFString,&value) == .success,let window=value else{return ""}
        var title:CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,kAXTitleAttribute as CFString,&title) == .success else{return ""}
        return title as? String ?? ""
    }
    func autoCategory(now:Date)->StudyCategory? {
        if testing{return testZoomTitle.map {StudyCategory.isZoomMeetingTitle($0) ? .lesson:nil} ?? testCategory}
        if zoomLessons && zoomMeetingActive(){return .lesson}
        guard let app=NSWorkspace.shared.frontmostApplication else{return nil}
        let name=(app.localizedName ?? "").lowercased(),bundle=(app.bundleIdentifier ?? "").lowercased()
        if bundle=="org.frenchstudytracker.app" {return previousCategory}
        if name.contains("anki") {pollAnki(now:now);return now.timeIntervalSince(lastAnkiCard)<20 ? ankiCategory:nil}
        if name.contains("法语")||name.contains("法語")||bundle.contains("french") {return .dictionary}
        let window=title(of:app).lowercased()
        let french=window.contains("法語")||window.contains("法语")||window.contains("french")||window.contains("français")
        if name.contains("chatgpt")||name.contains("codex")||bundle.contains("openai") {return chatStudy||french ? .chat:nil}
        if name.contains("safari")||name.contains("chrome")||name.contains("edge")||name.contains("firefox") {
            if window.contains("édito")||window.contains("edito")||window.contains("didier")||window.contains("法語練習") {return .materials}
            if (window.contains("chatgpt")||window.contains("codex")) && french {return .chat}
            if window.contains("法语助手")||window.contains("法語助手") {return .dictionary}
        }
        return nil
    }
    func zoomMeetingActive()->Bool {
        if testing{return testCategory == .lesson}
        guard trusted else{return false}
        for app in NSWorkspace.shared.runningApplications {
            let name=(app.localizedName ?? "").lowercased(),bundle=(app.bundleIdentifier ?? "").lowercased()
            guard bundle=="us.zoom.xos" || name=="zoom.us" || name=="zoom workplace" else{continue}
            let element=AXUIElementCreateApplication(app.processIdentifier);var value:CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,kAXWindowsAttribute as CFString,&value) == .success,let windows=value as? [AXUIElement] else{continue}
            for window in windows {var text:CFTypeRef?;if AXUIElementCopyAttributeValue(window,kAXTitleAttribute as CFString,&text) == .success,let title=text as? String,StudyCategory.isZoomMeetingTitle(title){return true}}
        }
        return false
    }
    func pollAnki(now:Date){
        guard !ankiBusy,now.timeIntervalSince(lastAnkiCheck)>4 else{return};lastAnkiCheck=now;ankiBusy=true
        var request=URLRequest(url:URL(string:"http://127.0.0.1:8765")!);request.httpMethod="POST";request.timeoutInterval=2;request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try? JSONSerialization.data(withJSONObject:["action":"guiCurrentCard","version":6])
        URLSession.shared.dataTask(with:request){[weak self]data,_,_ in
            let object=data.flatMap{try? JSONSerialization.jsonObject(with:$0)} as? [String:Any]
            let card=object?["result"] as? [String:Any]
            DispatchQueue.main.async{guard let self else{return};self.ankiBusy=false
                if let deck=card?["deckName"] as? String {self.ankiCategory=(deck.contains("French")||deck.contains("法語")) ? .anki:nil;self.lastAnkiCard=Date()}
                else if Date().timeIntervalSince(self.lastAnkiCard)>15 {self.ankiCategory=nil}
            }
        }.resume()
    }
    func tick(){
        let now=Date(),gap=now.timeIntervalSince(previous),idleSeconds=min(idle(),max(0,Date().timeIntervalSince(lastExplicitActivity)));trusted=AXIsProcessTrusted()
        let lastInput=now.addingTimeInterval(-max(0,idleSeconds))
        if !sleeping, gap>0,gap<15 {draft.add(start:previous,end:now,category:previousCategory)}
        let previousIgnoresIdle=StudyCategory.ignoresIdle(previousCategory,keep:keep)
        draft.confirm(through:previousIgnoresIdle && !sleeping ? now:lastInput,dropRemainder:!previousIgnoresIdle && idleSeconds>=900)
        let automatic=autoCategory(now:now)
        if ended {if automatic != lastAutoCategory || automatic==nil {rearm=true};if rearm && automatic != nil {ended=false;rearm=false}}
        lastAutoCategory=automatic
        // A manual timer must follow a meeting that starts after the timer.
        // Manual self-study resumes when the meeting ends; explicit pause still wins.
        var category=manual ? (automatic == .lesson ? .lesson:.chat):automatic
        let ignoresIdle=StudyCategory.ignoresIdle(category,keep:keep)
        if paused||ended||sleeping||(!ignoresIdle && idleSeconds>=900){category=nil}
        previousCategory=category;previous=now
        if sleeping {status="Paused · Mac asleep or locked"}
        else if ended {status="Paused · Waiting to study"}
        else if paused {status="Paused manually"}
        else if !ignoresIdle && idleSeconds>=900 {status="Paused · Idle for 15 minutes"}
        else if let category {status=(manual ? "Manual timer · ":"Auto timer · ")+category.label}
        else {status="Waiting for French study"}
        refresh()
        if now.timeIntervalSince(lastSave)>15 {save();lastSave=now}
        if now.timeIntervalSince(lastSync)>60 {sync()}
    }
    func refresh(){today=ledger.totals[Ledger.day(Date())] ?? [:];week=ledger.weekSeconds(now:Date(),includePending:false);draftSeconds=draft.seconds;let seconds=Int(draftSeconds);onTitle?(String(format:"🇫🇷 %02d:%02d",seconds/60,seconds%60)+(previousCategory==nil ? " Ⅱ":" ●"))}
    func userBoundary(){let now=Date();lastExplicitActivity=now;if now.timeIntervalSince(previous)<15{draft.add(start:previous,end:now,category:previousCategory)};draft.confirm(through:now);previous=now}
    func start(){userBoundary();sleeping=false;selected=zoomMeetingActive() ? .lesson:.chat;manual=true;paused=false;ended=false;tick();save()}
    func end(){userBoundary();manual=false;paused=false;ended=true;rearm=false;chatStudy=false;previousCategory=nil;status="Paused · Not yet recorded";refresh();save()}
    func togglePause(){if previousCategory==nil{start()}else{userBoundary();paused=true;previousCategory=nil;tick();save()}}
    func resetTimer(){
        do {
            if !testing {
                try dataSave(TimerSnapshot(ledger:ledger,draft:draft),to:"timer-before-reset.json")
                try dataSave(TimerSnapshot(ledger:ledger,draft:DraftTimer()),to:"snapshot.json")
            }
            draft=DraftTimer();manual=false;paused=true;ended=false;rearm=false
            previousCategory=nil;previous=Date();recordMessage="Timer reset";correctionMessage=""
            status="Paused · Timer reset";refresh();save()
        } catch {correctionMessage="Could not reset. Your timer is preserved. Please retry."}
    }
    func setKeep(_ value:Bool){userBoundary();keep=value;tick()}
    func sleep(){let now=Date();if !sleeping,now.timeIntervalSince(previous)<15{draft.add(start:previous,end:now,category:previousCategory)};let continuous=StudyCategory.ignoresIdle(previousCategory,keep:keep);draft.confirm(through:continuous ? now:now.addingTimeInterval(-idle()),dropRemainder:true);sleeping=true;previousCategory=nil;previous=now;refresh();save()}
    func wake(){sleeping=false;previous=Date();previousCategory=nil;tick();sync()}
    func save(){guard !testing else{return};do{try dataSave(TimerSnapshot(ledger:ledger,draft:draft),to:"snapshot.json");try dataSave(ledger,to:"ledger.json");try dataSave(draft,to:"draft.json");try dataSave(["mode":manual ? "manual":"auto","paused":String(paused),"sleeping":String(sleeping),"status":status,"draftSeconds":String(draftSeconds),"trusted":String(trusted),"updatedAt":ISO8601DateFormatter().string(from:Date())],to:"status.json")}catch{syncing="Could not save locally. Check disk permissions."}}
    func record(as category:StudyCategory){
        userBoundary()
        guard draft.seconds>0 else{return}
        let beforeLedger=ledger,beforeDraft=draft
        let seconds=draft.record(into:&ledger,as:category)
        ledger.recordedThrough=Date()
        do{
            // Save both together so retrying after a crash cannot count this timer twice.
            if !testing {try dataSave(TimerSnapshot(ledger:ledger,draft:draft),to:"snapshot.json")}
            recordMessage="Added to "+(category == .lesson ? "tutoring":"self-study")+": \(Int(seconds)/60)m \(Int(seconds)%60)s"
            refresh();save();sync()
        }catch{ledger=beforeLedger;draft=beforeDraft;correctionMessage="Could not save. Your timer is preserved. Please retry.";refresh()}
    }
    @discardableResult func setMinutes(lesson:Bool,text:String)->Bool{
        guard let minutes=Int(text.trimmingCharacters(in:.whitespacesAndNewlines)) else{correctionMessage="Enter a whole number of minutes.";return false}
        userBoundary()
        if ledger.setGroupMinutes(day:Ledger.day(Date()),lesson:lesson,minutes:minutes){
            ledger.recordedThrough=Date();correctionMessage="";refresh();save();sync();return true
        }else{correctionMessage="Minutes must be zero or more. Daily total cannot exceed 24 hours.";return false}
    }
    func sync(){
        guard !testing else{return}
        guard !inFlight else{return};lastSync=Date()
        guard let config,let url=URL(string:config.url+"/api/sync"),url.scheme=="https" else {syncing="Cloud sync is not configured";return}
        inFlight=true;syncing="Syncing…"
        let body=try? JSONSerialization.data(withJSONObject:ledger.payload(now:Date()))
        // Keychain may wait for system permission; never block timer/UI callbacks.
        let cached=cachedCloudToken
        DispatchQueue.global(qos:.utility).async { [weak self] in
        guard let token=cached ?? tokenRead() else {DispatchQueue.main.async{self?.inFlight=false;self?.syncing="Connect cloud sync · Records saved locally"};return}
        var request=URLRequest(url:url);request.httpMethod="POST";request.timeoutInterval=20;request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("Bearer "+token,forHTTPHeaderField:"OAI-Sites-Authorization")
        request.httpBody=body
        URLSession.shared.dataTask(with:request){[weak self]_,response,error in DispatchQueue.main.async {guard let self else{return};self.inFlight=false
            if error==nil,let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode){self.syncing="Synced · "+DateFormatter.localizedString(from:Date(),dateStyle:.none,timeStyle:.short)}else{self.syncing="Sync failed · Records saved locally"}
        }}.resume()
        }
    }
    func connectCloud(){
        guard !testing else{return}
        syncing="Waiting for cloud credential access…"
        DispatchQueue.global(qos:.utility).async{[weak self] in
            let token=tokenRead(interactive:true)
            DispatchQueue.main.async{guard let self else{return};self.cachedCloudToken=token
                if token != nil {self.sync()}else{self.syncing="Not connected · Records saved locally"}
            }
        }
    }
    func requestAccessibility(){let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true];_ = AXIsProcessTrustedWithOptions(options as CFDictionary)}
}

struct TimerView:View {
    @ObservedObject var model:StudyModel
    @State private var selfText="0"
    @State private var lessonText="0"
    @State private var initialSelf="0"
    @State private var initialLesson="0"
    @FocusState private var editing:Bool?
    func duration(_ seconds:Double)->String {let m=Int(seconds/60);return m>=60 ? "\(m/60)h \(m%60)m":"\(m) min"}
    func clock(_ seconds:Double)->String {let s=Int(seconds);return String(format:"%02d:%02d:%02d",s/3600,s%3600/60,s%60)}
    func loadValues(){
        if editing != false {selfText=String(Int(model.today.filter{$0.key != "lesson"}.values.reduce(0,+)/60));initialSelf=selfText}
        if editing != true {lessonText=String(Int((model.today["lesson"] ?? 0)/60));initialLesson=lessonText}
    }
    func commit(_ lesson:Bool){
        let value=lesson ? lessonText:selfText,initial=lesson ? initialLesson:initialSelf
        guard value != initial else{return}
        if model.setMinutes(lesson:lesson,text:value){if lesson{initialLesson=value}else{initialSelf=value}}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            HStack{Text("🇫🇷 French Study").font(.headline);Spacer();Text("Today").font(.caption).foregroundColor(.secondary)}
            Text(model.previousCategory == nil ? "Paused · Waiting to study" : model.previousCategory == .lesson ? "Tutoring timer running":"Self-study timer running").font(.subheadline).foregroundColor(.secondary)
            VStack(alignment:.leading,spacing:8){
                HStack {
                    Text("Unrecorded time").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Reset"){editing=nil;model.resetTimer()}.buttonStyle(.borderless).font(.caption)
                        .disabled(model.draftSeconds<=0).help("Clear unrecorded time and pause. Recorded totals stay unchanged.")
                }
                HStack(spacing:12){
                    Text(clock(model.draftSeconds)).font(.system(size:26,weight:.medium,design:.monospaced)).monospacedDigit()
                    Spacer(minLength:0)
                    Button(action:{editing=nil;model.togglePause()}){Image(systemName:model.previousCategory == nil ? "play.fill":"pause.fill")}.buttonStyle(.borderless).accessibilityLabel(model.previousCategory == nil ? "Resume timer":"Pause timer")
                    Menu("Add to records"){
                        Button("Add to self-study"){editing=nil;model.record(as:.chat)}
                        Button("Add to tutoring"){editing=nil;model.record(as:.lesson)}
                    }.menuStyle(.borderlessButton).fixedSize().disabled(model.draftSeconds<=0)
                }
                Text(model.recordMessage.isEmpty ? "Time counts toward totals only after you add it.":model.recordMessage).font(.caption2).foregroundColor(.secondary)
            }
            Divider()
            Text(duration(model.today.values.reduce(0,+))).font(.system(size:34,weight:.medium,design:.rounded)).monospacedDigit()
            HStack{Text("Today’s total");Spacer();Text("This week "+duration(model.week))}.font(.caption).foregroundColor(.secondary)
            Divider()
            HStack{Text("Self-study");Spacer();TextField("Minutes",text:$selfText).multilineTextAlignment(.trailing).textFieldStyle(.plain).frame(width:90).focused($editing,equals:false).onSubmit{commit(false);editing=nil};Text("min").foregroundColor(.secondary)}
            HStack{Text("Tutoring");Spacer();TextField("Minutes",text:$lessonText).multilineTextAlignment(.trailing).textFieldStyle(.plain).frame(width:90).focused($editing,equals:true).onSubmit{commit(true);editing=nil};Text("min").foregroundColor(.secondary)}
            Text("Edit minutes. Press Enter or leave the field to save.").font(.caption2).foregroundColor(.secondary)
            if !model.correctionMessage.isEmpty {Text(model.correctionMessage).font(.caption).foregroundColor(.red)}
            HStack{Button("Manual start"){editing=nil;model.start()}.buttonStyle(.borderedProminent);Spacer();Button("Manual end"){editing=nil;model.end()}.buttonStyle(.bordered)}
            Text(model.syncing).font(.caption2).foregroundColor(.secondary)
        }.padding(24).frame(width:390)
        .onAppear{loadValues()}
        .onDisappear{if let editing {commit(editing)}}
        .onChange(of:model.today){_ in loadValues()}
        .onChange(of:editing){old,new in if let old {commit(old)};loadValues()}
    }
}

final class AppDelegate:NSObject,NSApplicationDelegate {
    var item:NSStatusItem!;var popover=NSPopover();var model:StudyModel!
    func applicationDidFinishLaunching(_ notification:Notification){
        model=StudyModel();if CommandLine.arguments.contains("--reset-timer"){model.resetTimer()};item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.title="🇫🇷 0 min";item.button?.target=self;item.button?.action=#selector(toggle);item.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
        model.onTitle={[weak self] title in self?.item.button?.title=title}
        popover.contentViewController=NSHostingController(rootView:TimerView(model:model));popover.behavior = .transient
        model.refresh();DispatchQueue.main.asyncAfter(deadline:.now()+1){self.toggle()}
    }
    @objc func toggle(){guard let button=item.button else{return};if NSApp.currentEvent?.type == .rightMouseUp {let menu=NSMenu();menu.addItem(withTitle:"Enable automatic detection",action:#selector(access),keyEquivalent:"");menu.addItem(withTitle:"Connect cloud sync",action:#selector(connect),keyEquivalent:"");menu.addItem(withTitle:"View cloud records",action:#selector(cloud),keyEquivalent:"");menu.addItem(.separator());menu.addItem(withTitle:"Quit",action:#selector(quit),keyEquivalent:"");for i in menu.items{i.target=self};menu.popUp(positioning:nil,at:NSPoint(x:0,y:button.bounds.minY),in:button);return};if popover.isShown{popover.performClose(nil)}else{NSApp.activate(ignoringOtherApps:true);popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)}}
    @objc func connect(){model.connectCloud()}
    @objc func access(){model.requestAccessibility()}
    @objc func cloud(){if let url=URL(string:model.config?.url ?? ""){NSWorkspace.shared.open(url)}}
    @objc func quit(){model.sleep();NSApp.terminate(nil)}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{model?.sleep();return .terminateNow}
}

@main struct Runner {
    static func main()throws{
        if CommandLine.arguments.contains("--self-test"){
            coreSelfTest()
            let model=StudyModel(testing:true);model.testIdle=1800;model.sleeping=true
            model.start()
            precondition(model.previousCategory == .chat && !model.sleeping,"手動開始必須立即生效，不受舊閒置或睡眠狀態阻擋")
            model.previous=Date().addingTimeInterval(-3);model.tick()
            precondition(model.draftSeconds>=3 && model.ledger.totals.isEmpty,"手動開始會跳秒但不入帳")
            model.togglePause();let paused=model.draftSeconds
            model.previous=Date().addingTimeInterval(-3);model.tick()
            precondition(abs(model.draftSeconds-paused)<0.01,"暫停時不增加")
            model.togglePause();model.previous=Date().addingTimeInterval(-3);model.tick()
            precondition(model.draftSeconds>paused+2,"繼續時接續累加")
            model.end();model.record(as:.lesson)
            precondition(model.draftSeconds==0 && !model.ledger.totals.isEmpty,"加入紀錄才入帳並歸零")
            let total=model.ledger.totals;model.record(as:.lesson)
            precondition(model.ledger.totals==total,"不能重複入帳")
            model.start();model.previous=Date().addingTimeInterval(-3);model.tick()
            precondition(model.draftSeconds>0)
            let recordedBeforeReset=model.ledger.totals
            model.resetTimer()
            precondition(model.draftSeconds==0 && model.draft.confirmed.isEmpty && model.draft.pending.isEmpty)
            precondition(model.ledger.totals==recordedBeforeReset,"Reset must preserve recorded totals")
            model.previous=Date().addingTimeInterval(-3);model.tick()
            precondition(model.draftSeconds==0 && model.paused,"Reset must remain paused until explicitly resumed")
            model.record(as:.chat)
            precondition(model.ledger.totals==recordedBeforeReset,"Reset time must never be recorded")
            model.start();model.previous=Date().addingTimeInterval(-3);model.tick()
            precondition(model.draftSeconds>=3,"Start after reset begins a new timer")
            print("PASS: reset clears only draft, preserves ledger, pauses and can restart")
            let meeting=StudyModel(testing:true)
            meeting.testIdle=0;meeting.start()
            precondition(meeting.previousCategory == .chat)
            meeting.testIdle=1800;meeting.lastExplicitActivity=Date().addingTimeInterval(-1800)
            meeting.testZoomTitle="Zoom會議";meeting.tick()
            precondition(meeting.previousCategory == .lesson,"手動開始後進入 Zoom 必須轉為上課，忽略閒置")
            meeting.previous=Date().addingTimeInterval(-3);meeting.tick()
            precondition(meeting.draftSeconds>=3 && meeting.ledger.totals.isEmpty,"上課持續計時但仍不自動入帳")
            meeting.togglePause();meeting.tick()
            precondition(meeting.previousCategory == nil && meeting.paused,"Zoom 不得覆蓋手動暫停")
            meeting.togglePause();meeting.tick()
            precondition(meeting.previousCategory == .lesson,"手動繼續仍辨識上課")
            meeting.testZoomTitle="Zoom Workplace";meeting.testCategory=nil;meeting.testIdle=0;meeting.tick()
            precondition(meeting.previousCategory == .chat,"會議結束後回到手動自學")
            meeting.testIdle=1800;meeting.lastExplicitActivity=Date().addingTimeInterval(-1800);meeting.tick()
            precondition(meeting.previousCategory == nil,"會議結束後恢復自學閒置規則")
            meeting.testZoomTitle="Zoom會議";meeting.sleeping=true;meeting.tick()
            precondition(meeting.previousCategory == nil,"上課也不能覆蓋睡眠狀態")
            print("PASS: manual timer follows Zoom meetings, preserves pause and sleep, and restores self-study idle rules")
            print("PASS: 實際按鈕模型的開始、跳秒、暫停、繼續、結束保留與手動入帳")
            return
        }
        if CommandLine.arguments.contains("--configure"){
            guard let line=readLine(),let data=line.data(using:.utf8) else {throw NSError(domain:"Config",code:2)}
            let value=try JSONSerialization.jsonObject(with:data) as! [String:String]
            guard let origin=value["url"],let url=URL(string:origin),url.scheme=="https",url.host != nil,let token=value["token"],!token.isEmpty else {throw NSError(domain:"Config",code:1)}
            try tokenSave(token);try dataSave(CloudConfig(url:origin),to:"cloud.json");print("Cloud configuration saved; credential stored in Keychain.");return
        }
        let app=NSApplication.shared;let delegate=AppDelegate();app.delegate=delegate;app.setActivationPolicy(.accessory);app.run();withExtendedLifetime(delegate){}
    }
}
