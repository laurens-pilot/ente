use std::collections::HashSet;

use super::input::{ClipMatches, ClipVectors};
use crate::ml_store::{Index, Match, MlStore, Result, SearchParams};

const SPARSE_FILE_FRACTION_DIVISOR: usize = 10;
const MAX_BATCH_FILE_IDS: usize = 8_000;

impl ClipVectors for MlStore {
    fn matches(&self, query: &[f32], min_similarity: f32) -> Result<ClipMatches> {
        self.search(Index::Clip, query, &search_params(min_similarity))
            .map(similarities)
    }

    fn try_matches_in_files(
        &self,
        queries: &[Vec<f32>],
        min_similarity: f32,
        file_ids: &mut dyn Iterator<Item = i64>,
    ) -> Result<Option<Vec<ClipMatches>>> {
        let max_sparse_files =
            (self.index_len(Index::Clip)? / SPARSE_FILE_FRACTION_DIVISOR).min(MAX_BATCH_FILE_IDS);
        let mut eligible = HashSet::new();
        for file_id in file_ids {
            eligible.insert(file_id);
            if eligible.len() > max_sparse_files {
                return Ok(None);
            }
        }
        let params = SearchParams {
            allowed_keys: Some(eligible.into_iter().map(|id| id.to_string()).collect()),
            ..search_params(min_similarity)
        };
        let matches = self.bulk_search(Index::Clip, queries, &params)?;
        Ok(Some(matches.into_iter().map(similarities).collect()))
    }

    fn vector(&self, file_id: i64) -> Result<Option<Vec<f32>>> {
        self.get_vector(Index::Clip, &file_id.to_string())
    }
}

fn search_params(min_similarity: f32) -> SearchParams {
    SearchParams {
        limit: None,
        max_distance: Some(1.0 - min_similarity),
        exact: true,
        allowed_keys: None,
    }
}

fn similarities(matches: Vec<Match>) -> ClipMatches {
    matches
        .into_iter()
        .filter_map(|found| Some((found.key.parse().ok()?, 1.0 - found.distance)))
        .collect()
}

#[cfg(test)]
mod tests {
    use crate::memories::input::ClipVectors;
    use crate::ml_db::{CLIP_EMBEDDING_DIMENSIONS, ClipEmbedding};
    use crate::ml_store::MlStore;

    fn clip(file_id: i64, values: [f64; 2]) -> ClipEmbedding {
        let mut embedding = vec![0.0; CLIP_EMBEDDING_DIMENSIONS];
        embedding[..2].copy_from_slice(&values);
        ClipEmbedding {
            file_id,
            embedding,
            version: 1,
        }
    }

    #[test]
    fn matches_report_cosine_similarity_down_to_the_minimum_and_vectors_come_back_by_file_id() {
        let directory = tempfile::tempdir().unwrap();
        let store = MlStore::open(directory.path().join("ente.ml.db")).unwrap();
        store
            .put_clip(&[
                clip(1, [1.0, 0.0]),
                clip(2, [0.6, 0.8]),
                clip(3, [0.0, 1.0]),
            ])
            .unwrap();
        store.fill_clip_index(false).unwrap();
        let mut query = vec![0.0; CLIP_EMBEDDING_DIMENSIONS];
        query[0] = 1.0;

        let mut matches = store.matches(&query, 0.5).unwrap();
        matches.sort_by_key(|&(file_id, _)| file_id);

        assert_eq!(
            matches
                .iter()
                .map(|&(file_id, _)| file_id)
                .collect::<Vec<_>>(),
            [1, 2]
        );
        assert!((matches[0].1 - 1.0).abs() < 1e-3);
        assert!((matches[1].1 - 0.6).abs() < 1e-2);
        let vector = store.vector(3).unwrap().unwrap();
        assert!(vector[1] > 0.99 && vector[0].abs() < 1e-6);
        assert_eq!(store.vector(4).unwrap(), None);
    }

    #[test]
    fn batching_resolves_sparse_file_ids_and_stops_collecting_dense_sets() {
        let directory = tempfile::tempdir().unwrap();
        let store = MlStore::open(directory.path().join("ente.ml.db")).unwrap();
        store
            .put_clip(&(1..=20).map(|id| clip(id, [1.0, 0.0])).collect::<Vec<_>>())
            .unwrap();
        store.fill_clip_index(false).unwrap();
        let mut query = vec![0.0; CLIP_EMBEDDING_DIMENSIONS];
        query[0] = 1.0;
        let queries = [query];
        let sparse = store
            .try_matches_in_files(&queries, 0.5, &mut [5, 5, 21].into_iter())
            .unwrap()
            .unwrap();
        let expected: Vec<_> = store
            .matches(&queries[0], 0.5)
            .unwrap()
            .into_iter()
            .filter(|&(id, _)| id == 5)
            .collect();
        assert_eq!(sparse, [expected]);
        let mut dense = 1..=10;
        assert_eq!(
            store
                .try_matches_in_files(&queries, 0.5, &mut dense)
                .unwrap(),
            None,
        );
        assert_eq!(dense.next(), Some(4));
    }
}
