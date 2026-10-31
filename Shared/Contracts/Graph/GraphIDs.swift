enum GraphTag: ContractIDTag {}
enum NodeTag: ContractIDTag {}
enum PortTag: ContractIDTag {}
enum EdgeTag: ContractIDTag {}
enum DraftTag: ContractIDTag {}

typealias GraphID = ContractID<GraphTag>
typealias NodeID = ContractID<NodeTag>
typealias PortID = ContractID<PortTag>
typealias EdgeID = ContractID<EdgeTag>
typealias DraftID = ContractID<DraftTag>
