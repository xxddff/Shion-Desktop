import SwiftUI

struct TodosView: View {
    @Environment(AppStore.self) private var store
    @Environment(JumpState.self) private var jump: JumpState?
    @State private var draft = ""
    @State private var selection: String? = nil
    @State private var showInspector = false

    private struct TodoGroup {
        let title: String
        let items: [Todo]
        var showDay = false
    }

    var body: some View {
        let groups = groupedTodos
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                    TextField("新待办", text: $draft)
                        .textFieldStyle(.plain)
                        .disabled(store.readOnly)
                        .onSubmit {
                            store.addTodo(draft)
                            draft = ""
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle(title: group.title, count: group.items.count)
                        VStack(spacing: 0) {
                            ForEach(group.items) { todo in
                                TodoRow(todo: todo, showDay: group.showDay)
                                    .onTapGesture {
                                        selection = todo.id
                                        showInspector = true
                                    }
                                Divider().opacity(0.6)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("待办")
        .navigationSubtitle(subtitle)
        .inspector(isPresented: $showInspector) {
            if let id = selection, let todo = store.todo(id) {
                TodoInspector(todo: todo)
            }
        }
        // a todo picked in ⌘K opens here
        .onChange(of: jump?.todo, initial: true) { _, id in
            guard let id else { return }
            selection = id
            showInspector = true
            jump?.todo = nil
        }
    }

    private var subtitle: String {
        let overdue = store.todos.filter { !$0.done && $0.overdue(at: store.now) }.count
        return overdue > 0 ? "今天 \(store.todayTodos.count) 件 · 逾期 \(overdue) 件" : "今天 \(store.todayTodos.count) 件"
    }

    private var groupedTodos: [TodoGroup] {
        let now = store.now
        let open = store.todos.filter { !$0.done }
        func key(_ todo: Todo) -> Date { todo.plannedDate ?? todo.deadlineDate ?? .distantFuture }
        let overdue = open.filter { $0.overdue(at: now) }
        let rest = open.filter { !overdue.contains($0) }.sorted { key($0) < key($1) }
        return [
            TodoGroup(title: "逾期", items: overdue, showDay: true),
            TodoGroup(title: "今天", items: rest.filter { Fmt.dayDiff(key($0), now) <= 0 }),
            TodoGroup(title: "明天", items: rest.filter { Fmt.dayDiff(key($0), now) == 1 }),
            TodoGroup(title: "以后", items: rest.filter { Fmt.dayDiff(key($0), now) > 1 }, showDay: true),
            TodoGroup(title: "已完成", items: store.todos.filter { $0.done }),
        ]
        .filter { !$0.items.isEmpty }
    }
}

struct TodoInspector: View {
    @Environment(AppStore.self) private var store
    let todo: Todo

    var body: some View {
        Form {
            Section {
                Text(todo.title).font(.t15)
                if todo.proposed {
                    Text("日期是建议的").font(.t12).foregroundStyle(Palette.warm)
                }
            }
            Section {
                LabeledContent("执行", value: todo.planLabel(now: store.now))
                LabeledContent("截止", value: todo.deadlineLabel(now: store.now))
                TodoDateEditor(todo: todo, field: "do_at", title: "执行日期")
                TodoDateEditor(todo: todo, field: "due_at", title: "截止日期")
                LabeledContent("领域", value: todo.area.label)
                LabeledContent("来自", value: todo.source)
                if todo.nudges > 0 {
                    LabeledContent("催过", value: "\(todo.nudges) 次")
                }
            }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
    }
}


struct TodoDateEditor: View {
    @Environment(AppStore.self) private var store
    let todo: Todo
    let field: String
    let title: String
    @State private var date = Date()
    @State private var timed = false
    var body: some View {
        VStack(alignment: .leading) {
            DatePicker(title, selection: $date, displayedComponents: timed ? [.date, .hourAndMinute] : [.date])
            Toggle("指定时刻", isOn: $timed)
            HStack {
                Button("保存") {
                    let value = timed ? ISO8601DateFormatter().string(from: date) : Fmt.isoDay(date)
                    store.pluginWrite("todos.update", ["id": .string(todo.id), field: .string(value), "proposed": false])
                }
                Button("清除日期") { store.pluginWrite("todos.update", ["id": .string(todo.id), field: .null]) }
            }
        }.disabled(!store.pluginData || store.readOnly)
        .onChange(of: todo, initial: true) {
            let instant = field == "do_at" ? todo.doAt : todo.dueAt
            date = (field == "do_at" ? todo.plannedDate : todo.deadlineDate) ?? store.now
            timed = instant != nil
        }
    }
}
