import CodingAgentKit
import Foundation

/// Every sentence a client shows about an expert, so three clients say the same thing about it.
public enum ExpertWords {
    public static var title: String { Localized.text("Experts") }
    public static var newExpert: String { Localized.text("New expert") }
    public static var newTask: String { Localized.text("New task") }
    public static var newTaskPlaceholder: String { Localized.text("What should it do?") }
    public static func newTaskFor(_ name: String) -> String { Localized.text("A new task for %@…", name) }
    public static var edit: String { Localized.text("Edit") }
    public static var bench: String { Localized.text("Bench") }
    public static var guards: String { Localized.text("Guards") }
    public static var notebook: String { Localized.text("Notebook") }
    public static var journal: String { Localized.text("Journal") }
    public static var watches: String { Localized.text("Watches") }
    public static var charter: String { Localized.text("Charter") }
    public static var skills: String { Localized.text("Skills") }
    public static var tasks: String { Localized.text("Tasks") }
    public static var retired: String { Localized.text("Retired") }
    public static var checkNow: String { Localized.text("Check now") }
    public static var checking: String { Localized.text("Checking…") }
    public static var showBrief: String { Localized.text("Show the brief") }
    public static var briefTitle: String { Localized.text("The brief") }
    public static var finishTask: String { Localized.text("Finish task") }
    public static var finishTaskDetail: String {
        Localized.text("Writes the journal entry and proposes what to keep in the notebook.")
    }
    public static var handToExpert: String { Localized.text("Hand to an expert…") }
    public static var makeFromChat: String { Localized.text("Make an expert from this chat…") }
    public static var makeFromSkill: String { Localized.text("From a skill") }
    public static var makeBlank: String { Localized.text("Start blank") }
    public static var create: String { Localized.text("Create") }
    public static var save: String { Localized.text("Save") }
    public static var cancel: String { Localized.text("Cancel") }
    public static var delete: String { Localized.text("Delete expert") }
    public static var deleteDetail: String {
        Localized.text("Its tasks stay, and its notebook and journal stay on the machine.")
    }
    public static var acceptAll: String { Localized.text("Accept all") }
    public static var later: String { Localized.text("Later") }
    public static var skip: String { Localized.text("Skip") }
    public static var tryAgain: String { Localized.text("Try again") }
    public static var name: String { Localized.text("Name") }
    public static var purpose: String { Localized.text("What it is for") }
    public static var folder: String { Localized.text("Folder") }
    public static var notebookFolder: String { Localized.text("Notebook folder") }
    public static var notebookOwn: String { Localized.text("Its own, beside the expert") }
    public static var notebookOwnShort: String { Localized.text("Its own") }
    public static var firstNotes: String { Localized.text("First notes") }
    public static var markAndColour: String { Localized.text("Mark and colour") }
    public static var letters: String { Localized.text("Letters") }
    public static var draftFromSkill: String { Localized.text("Draft from a skill") }
    public static var draftFromSkillDetail: String {
        Localized.text("The machine writes the charter, the bench and the guards from one.")
    }
    public static var folderPlaceholder: String { Localized.text("Folder it works in") }
    public static var model: String { Localized.text("Model") }
    public static var addBenchItem: String { Localized.text("Add a device or service") }
    public static var addGuard: String { Localized.text("Add a guard") }
    public static var guardsOnDemand: String { Localized.text("Only when asked") }
    public static var empty: String { Localized.text("No experts yet") }
    public static var emptyDetail: String {
        Localized.text("An expert is a standing role on a machine: each task starts fresh with its charter, notebook and devices, and ends with a journal entry and notes you accept or skip.")
    }
    public static var noNotes: String { Localized.text("No notes yet. A task's debrief proposes them.") }
    public static var noJournal: String { Localized.text("No tasks yet.") }
    public static var noGuards: String {
        Localized.text("No guards. A guard is a command that has to keep passing, like a test run or a measured number under a line.")
    }
    public static var noBench: String { Localized.text("No devices or services.") }
    public static var startsWithTitle: String { Localized.text("Starts with") }
    public static var lastingUnticked: String { Localized.text("Only true that day") }
    public static var drafting: String { Localized.text("Drafting…") }
    public static var draftFailed: String { Localized.text("The draft could not be made.") }

    /// For a machine that keeps no experts.
    public static func cannotKeep(_ machine: String) -> String {
        Localized.text("%@ cannot keep experts. Experts need a machine running claude-bridge 1.37 or newer.", machine)
    }

    public static func taskStarted(_ name: String) -> String { Localized.text("%@ is on it", name) }
    public static func startsWith(_ name: String) -> String { Localized.text("%@ starts with", name) }
    public static func handFailure(_ name: String) -> String { Localized.text("Hand the failure to %@", name) }
    public static var handFailureDetail: String { Localized.text("A new task that starts with the failing output") }
    /// A machine that keeps experts but did not answer this time.
    public static func notAnswering(_ machine: String) -> String { Localized.text("%@ is not answering", machine) }

    public static func handOverNote(_ source: String) -> String {
        Localized.text("Picking an expert starts a new task with “%@” carried as a brief. This chat stays as it is.", source)
    }

    public static var expertsSection: String { Localized.text("Experts") }
    public static func chooserDetail(_ machine: String) -> String { Localized.text("%@ · starts a new task", machine) }

    // MARK: Proposals

    public static func opLabel(_ op: ExpertProposal.Operation) -> String {
        switch op {
        case .add: return Localized.text("New")
        case .change: return Localized.text("Changed")
        case .retire: return Localized.text("Retire")
        }
    }

    /// The press that accepts one proposal: what it does to the notebook.
    public static func accept(_ op: ExpertProposal.Operation) -> String {
        switch op {
        case .add: return Localized.text("Add")
        case .change: return Localized.text("Change")
        case .retire: return Localized.text("Retire")
        }
    }

    public static func proposalState(_ state: ExpertProposal.State, op: ExpertProposal.Operation) -> String? {
        switch state {
        case .pending: return nil
        case .skipped: return Localized.text("Skipped")
        case .accepted:
            switch op {
            case .add: return Localized.text("Added")
            case .change: return Localized.text("Changed")
            case .retire: return Localized.text("Retired")
            }
        }
    }

    public static var debriefNothingChanged: String { Localized.text("Nothing changes until you accept it") }
    public static var debriefDrafting: String { Localized.text("Writing the debrief…") }
    public static var debriefDraftingDetail: String {
        Localized.text("A fork of this task, never saved, writes the journal entry and proposes notes.")
    }
    public static var debriefFailed: String { Localized.text("The debrief could not be written") }
    public static var debriefNothing: String { Localized.text("Nothing new for the notebook") }
    public static var debriefSettled: String { Localized.text("Notebook updated") }
    public static var journalEntry: String { Localized.text("Journal") }

    // MARK: Counts

    public static func notes(_ count: Int) -> String {
        count == 1 ? Localized.text("1 note") : Localized.text("%d notes", count)
    }

    public static func toReview(_ count: Int) -> String {
        count == 1 ? Localized.text("1 note to review") : Localized.text("%d notes to review", count)
    }

    public static func lastTasks(_ count: Int) -> String {
        count == 1 ? Localized.text("The last task") : Localized.text("The last %d tasks", count)
    }

    public static func skill(_ name: String) -> String { Localized.text("%@ skill", name) }

    public static func tokens(_ count: Int) -> String {
        let shown = count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : String(count)
        return Localized.text("%@ tokens, outside the conversation", shown)
    }
}
