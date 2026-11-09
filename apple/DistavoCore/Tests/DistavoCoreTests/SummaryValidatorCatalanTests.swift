import XCTest
@testable import DistavoCore

/// #3931 finding 3 (docs/findings-real-meetings-2026-10-25.md): the repetition-collapse guard of
/// #4011 must be proven on Catalan text (accents, apostrophes, "l·l"), not only English.
/// The fixture is invented; no meeting content.
final class SummaryValidatorCatalanTests: XCTestCase {
    private let healthy = """
    # Notes de la reunió

    ## Resum
    L'equip ha revisat l'estat del projecte i ha acordat que la migració de les dades acabarà \
    abans de final de mes. La Núria porta la coordinació amb el proveïdor i l'Albert prepara \
    la documentació tècnica per a la direcció. També s'ha decidit ajornar la intel·ligència \
    de la cerca fins que hi hagi més pressupost disponible per a l'any vinent.

    ## Accions
    - La Núria envia el calendari al proveïdor aquesta setmana.
    - L'Albert acaba la documentació abans de la propera reunió.
    """

    func testHealthyCatalanSummaryPasses() {
        XCTAssertEqual(SummaryValidator.validate(healthy), [])
    }

    func testCatalanLoopIsCaughtAsCollapse() {
        let loop = String(repeating: "i després l'equip ha dit que sí, ", count: 30)
        let looping = healthy + "\n\n## Notes\n" + loop
        let failures = SummaryValidator.validate(looping)
        XCTAssertTrue(failures.contains { $0.contains("repetition collapse") }, "\(failures)")
    }

    func testCatalanLoopWithAccentsAndMiddleDotIsCaught() {
        let loop = String(repeating: "la intel·ligència és molt important per això ", count: 25)
        let failures = SummaryValidator.validate(healthy + "\n\n" + loop)
        XCTAssertTrue(failures.contains { $0.contains("repetition collapse") }, "\(failures)")
    }
}
