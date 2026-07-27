use aro_sync_protocol::VersionedValue;
use std::collections::BTreeMap;

pub fn merge_fields(
    current: &mut BTreeMap<String, VersionedValue>,
    incoming: BTreeMap<String, VersionedValue>,
) -> Vec<String> {
    let mut changed = Vec::new();
    for (field, candidate) in incoming {
        let accepts = current
            .get(&field)
            .is_none_or(|existing| candidate.timestamp > existing.timestamp);
        if accepts {
            current.insert(field.clone(), candidate);
            changed.push(field);
        }
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;
    use aro_sync_protocol::HybridTimestamp;
    use serde_json::json;
    use uuid::Uuid;

    fn value(n: i64, device_id: Uuid) -> VersionedValue {
        VersionedValue {
            value: json!(n),
            timestamp: HybridTimestamp {
                physical_millis: 100,
                logical: 0,
                device_id,
            },
        }
    }

    #[test]
    fn device_id_deterministically_breaks_equal_clock_ties() {
        let low = Uuid::from_u128(1);
        let high = Uuid::from_u128(2);
        let mut current = BTreeMap::from([("rating".into(), value(1, low))]);
        merge_fields(
            &mut current,
            BTreeMap::from([("rating".into(), value(2, high))]),
        );
        assert_eq!(current["rating"].value, json!(2));
    }
}
