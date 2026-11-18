use crate::rewind::library::Library;
use crate::rewind::ranking::{Ranking, Spread};
use crate::rewind::report::Finale;

const FINALE_CANDIDATES: usize = 12;

pub(in crate::rewind) fn finale(library: &Library<'_>, ranking: &Ranking<'_>) -> Option<Finale> {
    let file_ids = ranking.best(
        library.eligible().filter(|file| file.file.is_favourite),
        Spread::Months,
        FINALE_CANDIDATES,
    );
    (!file_ids.is_empty()).then_some(Finale { file_ids })
}

#[cfg(test)]
mod tests {
    use crate::rewind::fixtures::{photo, request};
    use crate::rewind::library::Library;
    use crate::rewind::ranking::Ranking;
    use crate::rewind::report::Finale;
    use crate::rewind::{RewindStatus, compute_rewind};

    use super::finale;

    #[test]
    fn favourites_cover_the_months_before_repeating_one() {
        let mut files = vec![
            photo(1, "2026-01-03T10:00:00"),
            photo(2, "2026-01-05T10:00:00"),
            photo(3, "2026-01-09T10:00:00"),
            photo(4, "2026-02-14T10:00:00"),
            photo(5, "2026-03-20T10:00:00"),
            photo(6, "2026-07-11T10:00:00"),
        ];
        for file in &mut files {
            file.is_favourite = file.id != 4 && file.id != 5;
        }
        let finale_request = request(files);
        let library = Library::of_year(&finale_request).unwrap();

        assert_eq!(
            finale(&library, &Ranking::new(None, None)),
            Some(Finale {
                file_ids: vec![1, 6, 2, 3],
            })
        );
    }

    #[test]
    fn a_burst_across_months_does_not_push_a_month_out_of_the_finale() {
        let mut files = vec![
            photo(1, "2026-01-31T23:59:59"),
            photo(2, "2026-01-05T10:00:00"),
            photo(3, "2026-01-09T10:00:00"),
            photo(4, "2026-01-12T10:00:00"),
            photo(5, "2026-02-01T00:00:00"),
            photo(6, "2026-02-01T00:00:00"),
            photo(7, "2026-02-01T00:00:01"),
            photo(8, "2026-02-14T10:00:00"),
        ];
        for file in &mut files {
            file.is_favourite = true;
        }
        files[0].like_count = 1;

        let state = compute_rewind(&request(files), None, None, None).unwrap();
        let RewindStatus::Ready { report } = state.status else {
            panic!("expected a ready Rewind");
        };
        assert_eq!(report.finale.unwrap().file_ids, [1, 8, 2, 3, 4]);
    }

    #[test]
    fn a_single_favourite_is_enough_and_none_skips_the_list() {
        let mut files = vec![
            photo(1, "2026-01-03T10:00:00"),
            photo(2, "2026-05-03T10:00:00"),
        ];
        files[1].is_favourite = true;
        let one_favourite = request(files.clone());
        let library = Library::of_year(&one_favourite).unwrap();
        assert_eq!(
            finale(&library, &Ranking::new(None, None)),
            Some(Finale { file_ids: vec![2] })
        );

        files[1].is_favourite = false;
        let no_favourites = request(files);
        let library = Library::of_year(&no_favourites).unwrap();
        assert_eq!(finale(&library, &Ranking::new(None, None)), None);
    }
}
