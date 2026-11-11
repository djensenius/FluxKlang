extension AppModel {
    func reconcilePerformanceProjectWindow(_ window: WindowID, widthClass: WorkspaceWidthClass) throws {
        guard let session = performanceProjectSession else { return }
        _ = try PerformanceProjectSession.openOrCreate(
            existing: session, window: window, widthClass: widthClass
        )
    }

    func closePerformanceProjectWindow(_ window: WindowID) throws {
        guard let session = performanceProjectSession,
              session.navigation.windowProjects[window] == session.project.id else { return }
        try session.closeWindow(window)
    }
}
