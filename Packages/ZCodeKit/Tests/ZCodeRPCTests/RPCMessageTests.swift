import Foundation
import Testing
import ZCodeRPC
import ZCodeTestSupport
import ZCodeWire

struct RPCMessageTests {
    @Test func encodeUnAppelDeMethode() {
        let message = RPCMessage.request(.promise, id: 0, channel: "zcode-agent", name: "helloConversationV4", arg: .array([]))
        #expect(message.hex == "040406640600010b7a636f64652d6167656e74011368656c6c6f436f6e766572736174696f6e56340400")
    }

    @Test func encodeUneEcouteDEvenementDynamique() {
        let message = RPCMessage.request(.eventListen, id: 3, channel: "zcode-agent", name: "onDynamicSessionsIndexFrame",
                                         arg: .json(.object(["workspacePath": .string("/w")])))
        #expect(message.hex == "040406660603010b7a636f64652d6167656e74011b6f6e44796e616d696353657373696f6e73496e6465784672616d6505167b22776f726b737061636550617468223a222f77227d")
    }

    @Test func encodeUneAnnulation() {
        #expect(RPCMessage.dispose(.promiseCancel, id: 7).hex == "04020665060700")
    }

    @Test func litLesReponses() throws {
        #expect(try RPCMessage.parseResponse(Data(hex: "040106c80100")) == .initialize)
        let success = RPCSerializer.encode(.array([.int(201), .int(5)]), .json(.object(["ok": .bool(true)])))
        #expect(try RPCMessage.parseResponse(success) == .success(id: 5, data: .json(.object(["ok": .bool(true)]))))
        let event = RPCSerializer.encode(.array([.int(204), .int(2)]), .string("e"))
        #expect(try RPCMessage.parseResponse(event) == .event(id: 2, data: .string("e")))
        let failure = RPCSerializer.encode(.array([.int(202), .int(1)]), .json(.object(["message": .string("boom")])))
        #expect(try RPCMessage.parseResponse(failure) == .error(id: 1, data: .json(.object(["message": .string("boom")]))))
        let errorObject = RPCSerializer.encode(.array([.int(203), .int(4)]), .string("x"))
        #expect(try RPCMessage.parseResponse(errorObject) == .errorObject(id: 4, data: .string("x")))
    }

    @Test func toleresLesTypesDeReponseInconnus() throws {
        let message = RPCSerializer.encode(.array([.int(299), .int(1)]), .undefined)
        #expect(try RPCMessage.parseResponse(message) == .unknown(type: 299))
    }

    @Test func refuseUnEnTeteInvalide() {
        #expect(throws: RPCError.self) { try RPCMessage.parseResponse(RPCSerializer.encode(.string("x"), .undefined)) }
        #expect(throws: RPCError.self) { try RPCMessage.parseResponse(RPCSerializer.encode(.array([.int(201)]), .undefined)) }
    }

    @Test func litUneErreurDistante() {
        let error = RemoteError(.json(.object([
            "message": .string("client mismatch"),
            "name": .string("ZCodeV4Error"),
            "code": .string("fault.command.clientMismatch"),
            "stack": .array([]),
        ])))
        #expect(error.message == "client mismatch")
        #expect(error.name == "ZCodeV4Error")
        #expect(error.code == .string("fault.command.clientMismatch"))
        #expect(error.kind == nil)
        #expect(RemoteError(.undefined).message == "Erreur distante")
    }
}
