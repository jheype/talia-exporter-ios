import SwiftUI
import PhotosUI

struct IdeaBoardsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var search = ""
    @State private var creating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Space for your next idea.").font(.title3.bold())
                    Text("Boards, images and connections.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus") }
                    .buttonStyle(TaliaIconButtonStyle()).accessibilityLabel("New board")
            }
            WorkSearchField(text: $search, prompt: "Search boards")
            ForEach(store.boards.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { board in
                NavigationLink {
                    IdeasCanvasView(board: board)
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: board.isGeneral ? "square.grid.2x2" : "square.stack.3d.up")
                            .font(.title2).frame(width: 46, height: 54)
                            .background(Color.taliaTertiaryBackground, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(board.name).font(.headline)
                            Text(board.isGeneral ? "Unassigned ideas · \(board.nodeCount) items" : "\(board.nodeCount) items")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                    }.taliaCard()
                }.buttonStyle(.plain)
            }
            if store.boards.isEmpty && !store.loading.contains("boards") {
                WorkEmptyState(title: "Room to think", message: "Create a board to collect your ideas.", symbol: "lightbulb")
            }
        }.sheet(isPresented: $creating) { NewBoardSheet() }
    }
}

private struct NewBoardSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ideas = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Board name") { TextField("e.g. Product ideas", text: $name) }
                Section("Initial ideas") {
                    TextField("One idea per line (optional)", text: $ideas, axis: .vertical).lineLimit(4...10)
                }
            }.taliaSurface().navigationTitle("New board").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            Task {
                                if await store.createBoard(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    initialIdeas: ideas.split(separator: "\n").map(String.init)) { dismiss() }
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || name.count > 120 || store.isMutating)
                    }
                }
        }
    }
}

struct IdeasCanvasView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let board: WorkBoard
    @State private var zoom: CGFloat = 1
    @State private var mode = CanvasMode.move
    @State private var connectionStart: WorkNode?
    @State private var editedNode: WorkNode?
    @State private var deletingNode: WorkNode?
    @State private var addingIdea = false
    @State private var addingImage = false
    @State private var showConnections = false

    private enum CanvasMode: String, CaseIterable { case move = "Move", connect = "Connect" }
    private var canvas: WorkCanvas? { store.canvas?.board.id == board.id ? store.canvas : nil }
    private var canvasSize: CGSize {
        let nodes = canvas?.nodes ?? []
        return CGSize(width: max(800, nodes.map { $0.x + $0.width + 180 }.max() ?? 0),
                      height: max(1000, nodes.map { $0.y + $0.height + 180 }.max() ?? 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(canvas?.nodes.count ?? 0) items", systemImage: "square.on.square")
                Spacer()
                Button { zoom = max(0.25, zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 46)
                Button { zoom = min(2, zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
            }.font(.subheadline).padding(.horizontal, 20).frame(minHeight: 48)
            if let start = connectionStart {
                Text("Tap an item to connect with “\(start.title)”.")
                    .font(.caption).padding(12).frame(maxWidth: .infinity).background(Color.taliaTertiaryBackground)
            }
            if let canvas {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        ForEach(canvas.connections) { connection in
                            if let from = canvas.nodes.first(where: { $0.id == connection.fromNodeID }),
                               let to = canvas.nodes.first(where: { $0.id == connection.toNodeID }) {
                                CanvasConnection(from: from, to: to).stroke(Color(workHex: connection.colour), lineWidth: 2)
                            }
                        }
                        ForEach(canvas.nodes.sorted { $0.zIndex < $1.zIndex }) { node in
                            CanvasNodeView(node: node, scale: zoom, canMove: mode == .move && !store.isMutating,
                                selected: connectionStart?.id == node.id,
                                onTap: { select(node) },
                                onMove: { x, y in Task { await store.moveNode(node, x: x, y: y, boardID: board.id) } })
                                .contextMenu {
                                    Button("Open", systemImage: "square.and.pencil") { editedNode = node }
                                    Button("Connect from here", systemImage: "point.3.connected.trianglepath.dotted") {
                                        mode = .connect; connectionStart = node
                                    }
                                    Button("Remove from board", systemImage: "trash", role: .destructive) { deletingNode = node }
                                }
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: canvasSize.width * zoom, height: canvasSize.height * zoom, alignment: .topLeading)
                }
                .background(Color.taliaBackground)
                .overlay(alignment: .topLeading) {
                    if canvas.nodes.isEmpty {
                        WorkEmptyState(title: "Your ideas start here", message: "Add an idea or image using the toolbar below.", symbol: "lightbulb")
                            .padding(24).allowsHitTesting(false)
                    }
                }
            } else if store.loading.contains("canvas") {
                ProgressView("Opening board…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Board unavailable", systemImage: "square.stack.3d.up")
                } actions: { Button("Try again") { Task { await store.loadCanvas(board.id) } } }
            }
            HStack(spacing: 8) {
                ForEach(CanvasMode.allCases, id: \.self) { option in
                    Button {
                        mode = option; connectionStart = nil
                    } label: {
                        Label(option.rawValue, systemImage: option == .move ? "arrow.up.and.down.and.arrow.left.and.right" : "link")
                            .font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                            .background(mode == option ? Color.taliaTertiaryBackground : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button { addingImage = true } label: {
                    Label("Image", systemImage: "photo").font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                }
                Button { addingIdea = true } label: {
                    Label("Idea", systemImage: "plus").font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(Color.taliaOnAccent).background(Color.taliaAccent, in: RoundedRectangle(cornerRadius: 12))
                }
            }.buttonStyle(.plain).padding(12).background(Color.taliaSecondaryBackground).disabled(store.isMutating)
        }
        .taliaSurface().navigationTitle(board.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.loadCanvas(board.id) } }
                    Button("Connections", systemImage: "link") { showConnections = true }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
            }
        }
        .task(id: board.id) { await store.loadCanvas(board.id) }
        .sheet(isPresented: $addingIdea) { IdeaEditor(board: board) }
        .sheet(isPresented: $addingImage) { IdeaEditor(board: board, imageOnly: true) }
        .sheet(item: $editedNode) { node in IdeaEditor(board: board, node: node) }
        .sheet(isPresented: $showConnections) { connectionsSheet }
        .confirmationDialog("Remove this item from the shared board?", isPresented: Binding(
            get: { deletingNode != nil }, set: { if !$0 { deletingNode = nil } }), titleVisibility: .visible) {
            Button("Remove item", role: .destructive) {
                if let node = deletingNode { Task { await store.removeNode(node, boardID: board.id) } }
                deletingNode = nil
            }
        }
    }

    private func select(_ node: WorkNode) {
        guard !store.isMutating else { return }
        if mode == .connect {
            if let start = connectionStart {
                Task { await store.connect(start, node, boardID: board.id) }
                connectionStart = nil
            } else { connectionStart = node }
        } else { editedNode = node }
    }

    private var connectionsSheet: some View {
        NavigationStack {
            List {
                ForEach(canvas?.connections ?? []) { connection in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(canvas?.nodes.first { $0.id == connection.fromNodeID }?.title ?? "Item") → \(canvas?.nodes.first { $0.id == connection.toNodeID }?.title ?? "Item")")
                        Button("Remove connection", role: .destructive) {
                            Task { await store.removeConnection(connection, boardID: board.id) }
                        }.disabled(store.isMutating)
                    }.padding(.vertical, 6)
                }
                if canvas?.connections.isEmpty != false { Text("No connections yet.").foregroundStyle(.secondary) }
            }.taliaSurface().navigationTitle("Connections").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showConnections = false } } }
        }
    }
}

private struct CanvasConnection: Shape {
    let from: WorkNode
    let to: WorkNode
    func path(in rect: CGRect) -> Path {
        let start = CGPoint(x: from.x + from.width / 2, y: from.y + from.height / 2)
        let end = CGPoint(x: to.x + to.width / 2, y: to.y + to.height / 2)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: (start.x + end.x) / 2, y: start.y),
                      control2: CGPoint(x: (start.x + end.x) / 2, y: end.y))
        return path
    }
}

private struct CanvasNodeView: View {
    let node: WorkNode
    let scale: CGFloat
    let canMove: Bool
    let selected: Bool
    let onTap: () -> Void
    let onMove: (Int, Int) -> Void
    @GestureState private var translation = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: node.kind == "image" ? "photo" : "lightbulb")
                Spacer()
                if canMove {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                        .gesture(DragGesture(coordinateSpace: .global)
                            .updating($translation) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                onMove(node.x + Int(value.translation.width / scale),
                                       node.y + Int(value.translation.height / scale))
                            })
                        .accessibilityLabel("Move \(node.title)")
                }
            }.font(.caption).foregroundStyle(.secondary)
            if let idea = node.idea {
                Text(idea.title).font(.headline).lineLimit(3)
                if !idea.description.isEmpty { Text(idea.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                if let image = idea.images.first { WorkspaceMediaView(media: image, isIdea: true).frame(maxHeight: 100) }
            } else if let image = node.image {
                WorkspaceMediaView(media: image, isIdea: true).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(width: CGFloat(node.width), height: CGFloat(node.height), alignment: .topLeading)
        .background(Color.taliaSecondaryBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Color.taliaAccent : Color(workHex: node.borderColour), lineWidth: selected ? 3 : 1.5) }
        .clipped().contentShape(Rectangle()).onTapGesture(perform: onTap)
        .offset(x: CGFloat(node.x) + translation.width / scale, y: CGFloat(node.y) + translation.height / scale)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open", onTap)
    }
}

private struct IdeaEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let board: WorkBoard
    var node: WorkNode?
    var imageOnly = false
    @State private var title = ""
    @State private var detail = ""
    @State private var colour = "#A8A8A8"
    @State private var selection: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @State private var loadingPhotos = false
    @State private var saving = false
    private let colours = ["#A8A8A8", "#D1B28A", "#76A88B", "#8C9CB8", "#B18D9F"]
    private var latestNode: WorkNode? { store.canvas?.nodes.first { $0.id == node?.id } ?? node }
    private var valid: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && title.count <= 200 && detail.count <= 4000 && (!imageOnly || !photos.isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                if node?.kind != "image" {
                    Section("Idea") {
                        TextField("Title", text: $title)
                        TextField("Description", text: $detail, axis: .vertical).lineLimit(3...8)
                    }
                }
                Section("Border") {
                    HStack {
                        ForEach(colours, id: \.self) { hex in
                            Button { colour = hex } label: {
                                Circle().fill(Color(workHex: hex)).frame(width: 28, height: 28)
                                    .overlay { if colour == hex { Image(systemName: "checkmark").foregroundStyle(.black) } }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.plain).accessibilityLabel(hex).accessibilityAddTraits(colour == hex ? .isSelected : [])
                        }
                    }
                }
                Section("Images") {
                    if let image = node?.image { WorkspaceMediaView(media: image, isIdea: true) }
                    ForEach(latestNode?.idea?.images ?? []) { image in
                        VStack {
                            WorkspaceMediaView(media: image, isIdea: true)
                            Button("Place a copy on the canvas") { Task { await store.placeImage(image, boardID: board.id) } }
                                .disabled(store.isMutating)
                        }
                    }
                    ForEach(photos.indices, id: \.self) { index in
                        if let image = UIImage(data: photos[index]) {
                            HStack {
                                Image(uiImage: image).resizable().scaledToFit().frame(height: 80)
                                Spacer()
                                Button("Remove", role: .destructive) { photos.remove(at: index) }
                            }
                        }
                    }
                    if node?.kind != "image" {
                        PhotosPicker(selection: $selection, maxSelectionCount: 4, matching: .images) {
                            Label(loadingPhotos ? "Preparing images…" : "Choose images", systemImage: "photo.badge.plus")
                        }.disabled(loadingPhotos || saving)
                    }
                }
            }.taliaSurface().navigationTitle(node == nil ? (imageOnly ? "Add image" : "New idea") : "Edit item")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") { Task { await save() } }
                            .disabled((node?.kind != "image" && !valid) || saving || loadingPhotos || store.isMutating)
                    }
                }
        }
        .interactiveDismissDisabled(saving)
        .onAppear {
            title = node?.idea?.title ?? (imageOnly ? "Image reference" : "")
            detail = node?.idea?.description ?? ""
            colour = node?.borderColour ?? "#A8A8A8"
        }
        .task(id: selection) {
            guard !selection.isEmpty else { return }
            loadingPhotos = true
            defer { loadingPhotos = false }
            do {
                var result: [Data] = []
                for item in selection {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        result.append(try await WorkspaceImageIO.prepareJPEG(data))
                    }
                    try Task.checkCancellation()
                }
                photos = result
            } catch { if !Task.isCancelled { store.errorMessage = "An image could not be opened. Please choose it again." } }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if let current = latestNode {
            // Use the editor's original version: a background refresh must not silently overwrite another editor.
            if let idea = node?.idea {
                guard await store.editIdea(idea, title: title, description: detail, boardID: board.id) else { return }
                if !photos.isEmpty { await store.uploadImages(photos, to: idea, boardID: board.id) }
            }
            if colour != current.borderColour {
                await store.colourNode(latestNode ?? current, colour: colour, boardID: board.id)
            }
            if store.errorMessage == nil { dismiss() }
        } else if await store.addIdea(board: board, title: title, description: detail,
                                     colour: colour, imageData: photos, assetOnly: imageOnly) {
            dismiss()
        }
    }
}

