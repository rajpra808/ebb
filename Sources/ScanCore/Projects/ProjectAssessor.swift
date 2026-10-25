import Foundation

/// The verdict on one project.
struct ProjectAssessment: Sendable {
    let project: Project
    /// Empty for inactive projects.
    let evidence: [ActivityEvidence]
    /// The full walk, present for inactive projects (their leftovers are
    /// what gets reported).
    let survey: ProjectSurvey?
    /// Newest edit or git event, used for "inactive 41 days".
    let lastActivity: Date?

    var isActive: Bool { !evidence.isEmpty }
}

/// Runs every activity signal over every project.
struct ProjectAssessor: Sendable {
    let signals: [any ActivitySignal]
    let leftoverRules: [LeftoverRule]
    let now: Date
    let activeSince: Date
    let maxConcurrency: Int

    func assess(_ projects: [Project]) async -> [ProjectAssessment] {
        await projects.concurrentMap(maxConcurrency: maxConcurrency) { project in
            await assess(project)
        }
    }

    func assess(_ project: Project) async -> ProjectAssessment {
        let rules = leftoverRules
        let cutoff = activeSince
        let cache = Locked<ProjectSurvey?>(nil)
        let survey: @Sendable () async -> ProjectSurvey = {
            if let cached = cache.withLock({ $0 }) { return cached }
            let fresh = await BlockingIO.run {
                ProjectSurvey.take(of: project.root, rules: rules, stopAtEditsAfter: cutoff)
            }
            cache.withLock { $0 = fresh }
            return fresh
        }

        let context = ActivityContext(now: now, activeSince: activeSince, survey: survey)
        var evidence: [ActivityEvidence] = []
        for signal in signals {
            if let found = await signal.evaluate(project, in: context) {
                evidence.append(found)
            }
        }
        if !evidence.isEmpty {
            return ProjectAssessment(project: project, evidence: evidence, survey: nil, lastActivity: nil)
        }

        var full = await survey()
        if full.stoppedEarly {
            // Only possible when the recent-edit signal is switched off; walk
            // again without the cutoff so the leftover list is complete.
            full = await BlockingIO.run {
                ProjectSurvey.take(of: project.root, rules: rules, stopAtEditsAfter: .distantFuture)
            }
        }
        let lastActivity = [full.newestEdit?.date, GitActivity.latest(in: project.root)?.date]
            .compactMap { $0 }
            .max()
        return ProjectAssessment(project: project, evidence: [], survey: full, lastActivity: lastActivity)
    }
}
