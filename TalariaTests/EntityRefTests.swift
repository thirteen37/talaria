import Testing
@testable import Talaria

@Suite
struct EntityRefTests {
    /// Every entity maps to the browse page that manages it — the table the whole
    /// hot-link feature routes on. A regression here sends a link to the wrong
    /// page.
    @Test
    func destinationMapping() {
        #expect(EntityRef.modelMain.destination == .models)
        #expect(EntityRef.modelAuxiliary(task: "fast").destination == .models)
        #expect(EntityRef.hermesProfile(name: "prod").destination == .hermesProfiles)
        #expect(EntityRef.skill(id: "pdf").destination == .extensions)
        #expect(EntityRef.tool(name: "web").destination == .extensions)
        #expect(EntityRef.mcpServer(name: "fs").destination == .extensions)
        #expect(EntityRef.plugin(name: "kanban").destination == .extensions)
        #expect(EntityRef.cronJob(id: "job1").destination == .cron)
        #expect(EntityRef.personality(name: "coder").destination == .personalities)
        #expect(EntityRef.envVar(name: "API_KEY").destination == .profiles)
        #expect(EntityRef.kanbanBoard(slug: "ops").destination == .kanban)
        // `.session` opens the chat, not a browse page; its destination is only a
        // placeholder routers never consult.
        #expect(EntityRef.session("sid").destination == .sessions)
    }

    /// Model refs expose the picker slot the Models page should open; non-model
    /// refs don't.
    @Test
    func modelPickerTargetMapping() {
        #expect(EntityRef.modelMain.modelPickerTarget == .main)
        #expect(EntityRef.modelAuxiliary(task: "title").modelPickerTarget == .auxiliary(task: "title"))
        #expect(EntityRef.skill(id: "pdf").modelPickerTarget == nil)
        #expect(EntityRef.session("sid").modelPickerTarget == nil)
    }

    /// Routers special-case `.session` via this accessor before consulting
    /// `destination`.
    @Test
    func sessionIdAccessor() {
        #expect(EntityRef.session("abc123").sessionId == "abc123")
        #expect(EntityRef.modelMain.sessionId == nil)
        #expect(EntityRef.hermesProfile(name: "prod").sessionId == nil)
    }
}
