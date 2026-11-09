/// Why a projection of registry records into device descriptors was refused. A refusal covers the whole input and
/// nothing partial is returned. It is not a case of `DeviceRegistryRefusal`, which the registry itself produces.
enum DeviceDescriptorProjectionRefusal: Error, Hashable, Sendable {
    /// More records than `DeviceCapabilityLimits.devices`, decided from the count alone.
    case tooManyDevices(count: Int, maximum: Int)
    /// The first record, in input order, whose id repeats an earlier record's id.
    case duplicateDeviceID(DeviceID)
    /// The contract refused the descriptor built from this record. Defensive: no test exercises it.
    case invalidDescriptor(DeviceID)
}
