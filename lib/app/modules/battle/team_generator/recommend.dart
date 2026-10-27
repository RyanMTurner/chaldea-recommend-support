import 'package:chaldea/app/app.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/packages/split_route/split_route.dart';
import 'package:chaldea/utils/utils.dart';
import 'package:chaldea/widgets/widgets.dart';

/// Team recommendations for the Team Generator.
///
/// Placeholder until the recommendation algorithm exists: the user's owned servants, newest first
/// (highest collection number), 6 at a time.
class TeamRecommender {
  static List<List<Servant>> recommend() {
    final owned = [
      for (final svt in db.gameData.servantsNoDup.values)
        if (svt.collectionNo > 0 && db.curUser.servants[svt.collectionNo]?.favorite == true) svt,
    ];
    owned.sort((a, b) => b.collectionNo - a.collectionNo);
    return [
      for (int start = 0; start < owned.length; start += 6) owned.sublist(start, (start + 6).clamp(0, owned.length)),
    ];
  }
}

/// Recommended teams, shown in the right half of the screen; "Select" fills a team into the Team Generator.
class TeamRecommendPage extends StatelessWidget {
  final List<List<Servant>> teams;
  final void Function(List<Servant> team) onSelect;

  const TeamRecommendPage({super.key, required this.teams, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recommended Teams')),
      body: teams.isEmpty
          ? const Center(child: Text('No owned servants found.'))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: teams.length,
              itemBuilder: (context, index) => _teamCard(context, index, teams[index]),
            ),
    );
  }

  Widget _teamCard(BuildContext context, int index, List<Servant> team) {
    Widget slot(Servant? svt) => Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          svt == null
              ? const SizedBox(width: 48, height: 52)
              : svt.iconBuilder(context: context, width: 48, jumpToDetail: true),
          const SizedBox(height: 2),
          Text(
            svt?.lName.l ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Team ${index + 1}', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                FilledButton.tonal(
                  onPressed: () {
                    onSelect(team);
                    if (!SplitRoute.isSplit(context)) Navigator.of(context).maybePop();
                  },
                  child: Text(S.current.select),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < 3; i++) slot(team.getOrNull(i)),
                const SizedBox(height: 56, child: VerticalDivider(width: 12)),
                for (int i = 3; i < 6; i++) slot(team.getOrNull(i)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
