import Testing
import ZCodeAppCore
import ZCodeV4
import ZCodeWire

struct WorkflowArgsFormTests {
    static func spec(_ name: String, _ type: String, required: Bool = false, default value: JSONValue? = nil) -> WorkflowArgSpec {
        WorkflowArgSpec(name: name, type: WorkflowArgType(rawValue: type), description: nil, required: required, defaultValue: value)
    }

    @Test func défautsPréremplisEtPayload() {
        let form = WorkflowArgsForm(specs: [Self.spec("who", "string", default: .string("monde")),
                                            Self.spec("count", "number", required: true)])
        #expect(form.fields[0].text == "monde")
        #expect(form.errors == ["count": "Obligatoire"])
        #expect(form.payload() == nil)
    }

    @Test func virguleFrançaise() {
        var form = WorkflowArgsForm(specs: [Self.spec("n", "number")])
        form.fields[0].text = "3,5"
        #expect(form.payload() == ["n": .number(3.5)])
        form.fields[0].text = "abc"
        #expect(form.errors == ["n": "Nombre attendu"])
    }

    @Test func jsonInvalide() {
        var form = WorkflowArgsForm(specs: [Self.spec("j", "json", required: true)])
        form.fields[0].text = "{"
        #expect(form.errors == ["j": "JSON invalide"])
        form.fields[0].text = #"{"a":1}"#
        #expect(form.payload() == ["j": .object(["a": .number(1)])])
    }

    @Test func booléenJamaisTouché() {
        let optional = WorkflowArgsForm(specs: [Self.spec("b", "boolean")])
        #expect(optional.payload() == [:])
        let withDefault = WorkflowArgsForm(specs: [Self.spec("b", "boolean", default: .bool(true))])
        #expect(withDefault.payload() == ["b": .bool(true)])
        let required = WorkflowArgsForm(specs: [Self.spec("b", "boolean", required: true)])
        #expect(required.errors == ["b": "Obligatoire"])
    }

    @Test func défautDUnAutreTypeNonPrérempli() {
        let form = WorkflowArgsForm(specs: [Self.spec("n", "number", default: .string("x"))])
        #expect(form.fields[0].text == "")
        #expect(form.payload() == [:])
    }

    @Test func videNonRequisOmis() {
        let form = WorkflowArgsForm(specs: [Self.spec("s", "string"), Self.spec("j", "json")])
        #expect(form.payload() == [:])
    }
}
