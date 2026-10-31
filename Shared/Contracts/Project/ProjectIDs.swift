enum ProjectTag: ContractIDTag {}
enum RoleTag: ContractIDTag {}
enum PatchTag: ContractIDTag {}
enum AssetTag: ContractIDTag {}

typealias ProjectID = ContractID<ProjectTag>
typealias RoleID = ContractID<RoleTag>
typealias PatchID = ContractID<PatchTag>
typealias AssetID = ContractID<AssetTag>
