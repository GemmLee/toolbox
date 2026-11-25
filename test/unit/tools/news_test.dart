import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:toolbox/features/tools/news/aihot_api.dart';
import 'package:toolbox/features/tools/news/daily_news_page.dart';
import 'package:toolbox/features/tools/news/news_api.dart';
import 'package:toolbox/features/tools/news/news_cache.dart';
import '../../support/test_env.dart';

const String _hotBody = '{"schemaVersion":1,"count":2,"items":['
    '{"rank":1,"id":"a","title":"热点一","source":{"name":"来源A"},'
    '"links":{"aihot":"https://aihot.news/items/a","original":"https://a.example"},'
    '"sourceCount":9,"latestAt":"2026-11-18T01:04:01.000Z","sourceNames":["X","RSS"]},'
    '{"rank":2,"id":"b","title":"热点二","source":{"name":"来源B"},'
    '"links":{"aihot":"https://aihot.news/items/b"},"sourceCount":3}]}';

const String _aiItemsBody =
    '{"schemaVersion":1,"query":{"window":"24h"},"items":['
    '{"id":"i1","title":"精选一","summary":"摘要一","source":{"name":"来源X"},'
    '"links":{"aihot":"https://aihot.news/items/i1","original":"https://x.example"},'
    '"publishedAt":"2026-11-18T23:41:28.000Z","category":"industry","score":77},'
    '{"id":"i2","title":"精选二","summary":null,"source":{"name":"来源Y"},'
    '"links":{"aihot":"https://aihot.news/items/i2"},'
    '"publishedAt":null,"score":null}]}';

AiHotService _aiServiceWith(Future<http.Response> Function(http.Request) fn) =>
    AiHotService(client: MockClient(fn), timeout: const Duration(seconds: 3));

/// 切换条某段是否处于选中态：选中段文字为 w600，未选为 w400。
bool _tabActive(WidgetTester tester, String key) {
  final text = tester.widget<Text>(find.byKey(ValueKey(key)));
  return (text.style?.fontWeight ?? FontWeight.normal) == FontWeight.w600;
}

const String _okBody = '{"code":200,"message":"ok","data":{'
    '"date":"2026-11-01","news":["新闻一","新闻二"],'
    '"tip":"保持热爱","day_of_week":"星期日","lunar_date":"九月十二"}}';

DailyNewsService _serviceWith(
        Future<http.Response> Function(http.Request) fn) =>
    DailyNewsService(
      client: MockClient(fn),
      timeout: const Duration(seconds: 3),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(' DailyNewsService 解析', () {
    test('成功返回并解析字段', () async {
      final service = _serviceWith(
        (_) async => http.Response.bytes(utf8.encode(_okBody), 200),
      );
      final news = await service.fetch();
      expect(news.date, '2026-11-01');
      expect(news.news, <String>['新闻一', '新闻二']);
      expect(news.tip, '保持热爱');
      expect(news.dayOfWeek, '星期日');
      expect(news.lunarDate, '九月十二');
      service.dispose();
    });

    test('业务 code 非 200 抛异常', () async {
      final service = _serviceWith(
        (_) async => http.Response.bytes(
          utf8.encode('{"code":500,"message":"服务器开小差了"}'),
          200,
        ),
      );
      expect(
        () => service.fetch(),
        throwsA(isA<DailyNewsException>().having(
          (e) => e.message,
          'message',
          contains('服务器开小差了'),
        )),
      );
      service.dispose();
    });

    test('HTTP 非 200 抛异常', () async {
      final service = _serviceWith(
        (_) async => http.Response.bytes(utf8.encode('oops'), 502),
      );
      expect(service.fetch(), throwsA(isA<DailyNewsException>()));
      service.dispose();
    });

    test('新闻为空抛异常', () async {
      final service = _serviceWith(
        (_) async => http.Response.bytes(
          utf8.encode('{"code":200,"data":{"date":"2026-11-01","news":[]}}'),
          200,
        ),
      );
      expect(service.fetch(), throwsA(isA<DailyNewsException>()));
      service.dispose();
    });
  });

  group('DailyNewsPage 渲染', () {
    installCleanEnv();

    testWidgets('展示新闻并支持刷新', (tester) async {
      var calls = 0;
      final service = _serviceWith((_) async {
        calls++;
        return http.Response.bytes(utf8.encode(_okBody), 200);
      });

      await tester.pumpWidget(
        MaterialApp(home: DailyNewsPage(service: service)),
      );
      await tester.pumpAndSettle();

      expect(find.text('新闻一'), findsOneWidget);
      expect(find.text('新闻二'), findsOneWidget);
      expect(find.text('保持热爱'), findsOneWidget);
      expect(calls, 1);

      await tester.tap(find.byKey(const ValueKey('news-refresh')));
      await tester.pumpAndSettle();
      expect(calls, 2);
    });

    testWidgets('失败时显示重试入口', (tester) async {
      final service = _serviceWith(
        (_) async => http.Response.bytes(utf8.encode('x'), 500),
      );
      await tester.pumpWidget(
        MaterialApp(home: DailyNewsPage(service: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('加载失败'), findsOneWidget);
      service.dispose();
    });

    testWidgets('自动加载时只有中央加载圈，右上角保持刷新图标', (tester) async {
      final gate = Completer<http.Response>();
      final service = _serviceWith((_) => gate.future);

      await tester.pumpWidget(
        MaterialApp(home: DailyNewsPage(service: service)),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('news-refresh')),
      );
      expect(button.icon, isA<Icon>());
      expect((button.icon as Icon).icon, Icons.refresh);

      // 自动加载期间点击刷新不应叠加第二个加载圈或重复请求
      await tester.tap(find.byKey(const ValueKey('news-refresh')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(button.icon, isA<Icon>());

      gate.complete(http.Response.bytes(utf8.encode(_okBody), 200));
      await tester.pumpAndSettle();
      expect(find.text('新闻一'), findsOneWidget);
      service.dispose();
    });

    testWidgets('手动刷新时仅右上角按钮转圈，刷新期间重复点击不重复请求', (tester) async {
      var calls = 0;
      final gate = Completer<http.Response>();
      final service = _serviceWith((_) async {
        calls++;
        if (calls == 1) {
          return http.Response.bytes(utf8.encode(_okBody), 200);
        }
        return gate.future;
      });

      await tester.pumpWidget(
        MaterialApp(home: DailyNewsPage(service: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text('新闻一'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('news-refresh')));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('news-refresh')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      // 已有数据时手动刷新保留旧内容，屏幕上只有右上角一个圈
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('新闻一'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('news-refresh')));
      await tester.pump();
      expect(calls, 2);

      gate.complete(http.Response.bytes(utf8.encode(_okBody), 200));
      await tester.pumpAndSettle();
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('news-refresh')),
      );
      expect(button.icon, isA<Icon>());
      service.dispose();
    });

    testWidgets('缓存命中不请求，手动刷新仍更新', (tester) async {
      var calls = 0;
      Future<http.Response> respond(http.Request _) async {
        calls++;
        return http.Response.bytes(utf8.encode(_okBody), 200);
      }

      final first = _serviceWith(respond);
      await tester.pumpWidget(
        MaterialApp(home: DailyNewsPage(service: first)),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      final second = _serviceWith(respond);
      await tester.pumpWidget(
        MaterialApp(home: DailyNewsPage(service: second)),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('新闻一'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('news-refresh')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      first.dispose();
      second.dispose();
    });

    testWidgets('缓存超过24小时后重新请求', (tester) async {
      var now = DateTime(2026, 11, 19, 12);
      final cache = NewsCache(now: () => now);
      var calls = 0;
      Future<http.Response> respond(http.Request _) async {
        calls++;
        return http.Response.bytes(utf8.encode(_okBody), 200);
      }

      final first = _serviceWith(respond);
      await tester.pumpWidget(
        MaterialApp(home: DailyNewsPage(service: first, cache: cache)),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      now = now.add(const Duration(hours: 25));
      final second = _serviceWith(respond);
      await tester.pumpWidget(
        MaterialApp(home: DailyNewsPage(service: second, cache: cache)),
      );
      await tester.pumpAndSettle();
      expect(calls, 2);
      first.dispose();
      second.dispose();
    });
  });
  group('AiHotService 解析', () {
    test('热点榜解析字段与来源', () async {
      final service = _aiServiceWith(
        (_) async => http.Response.bytes(utf8.encode(_hotBody), 200),
      );
      final hot = await service.fetchHot();
      expect(hot.length, 2);
      expect(hot.first.rank, 1);
      expect(hot.first.title, '热点一');
      expect(hot.first.sourceName, '来源A');
      expect(hot.first.originalUrl, 'https://a.example');
      expect(hot.first.sourceNames, <String>['X', 'RSS']);
      service.dispose();
    });

    test('精选按窗口传参并解析，空字段容错', () async {
      Uri? used;
      final service = _aiServiceWith((req) async {
        used = req.url;
        return http.Response.bytes(utf8.encode(_aiItemsBody), 200);
      });
      final items = await service.fetchSelected('7d');
      expect(used!.queryParameters['mode'], 'selected');
      expect(used!.queryParameters['window'], '7d');
      // 7d 多取一页再按评分精选，才能和 24h 的最新十条区分。
      expect(used!.queryParameters['limit'], '50');
      expect(items.length, 2);
      expect(items.first.title, '精选一');
      expect(items.first.summary, '摘要一');
      expect(items.first.score, 77);
      expect(items.last.summary, '');
      expect(items.last.score, isNull);
      expect(items.last.timeLabel, '');
      service.dispose();
    });

    test('近7天按评分取前10条，而非最新10条', () async {
      final body = jsonEncode({
        'items': [
          for (var i = 1; i <= 12; i++)
            <String, Object>{'title': '精选$i', 'score': i},
        ],
      });
      final service = _aiServiceWith(
        (_) async => http.Response.bytes(utf8.encode(body), 200),
      );
      final items = await service.fetchSelected('7d');
      expect(items.length, 10);
      expect(items.first.title, '精选12');
      expect(items.last.title, '精选3');
      service.dispose();
    });

    test('HTTP 非 200 抛 AiHotException', () async {
      final service = _aiServiceWith(
        (_) async => http.Response.bytes(utf8.encode('oops'), 503),
      );
      expect(service.fetchHot(), throwsA(isA<AiHotException>()));
      service.dispose();
    });
  });

  group('DailyNewsPage AI速递版面', () {
    installCleanEnv();

    testWidgets('切到 AI速递显示热点与精选，切窗口重新按窗口请求', (tester) async {
      final windows = <String>[];
      final daily = _serviceWith(
        (_) async => http.Response.bytes(utf8.encode(_okBody), 200),
      );
      final ai = _aiServiceWith((req) async {
        if (req.url.path.endsWith('hot-topics')) {
          return http.Response.bytes(utf8.encode(_hotBody), 200);
        }
        windows.add(req.url.queryParameters['window'] ?? '');
        return http.Response.bytes(utf8.encode(_aiItemsBody), 200);
      });

      await tester.pumpWidget(MaterialApp(
        home: DailyNewsPage(service: daily, aiHotService: ai),
      ));
      await tester.pumpAndSettle();

      expect(find.text('新闻一'), findsOneWidget);
      expect(find.byKey(const ValueKey('news-tab-daily')), findsOneWidget);
      expect(find.byKey(const ValueKey('news-tab-ai')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('news-tab-ai')));
      await tester.pumpAndSettle();
      expect(find.text('热点一'), findsOneWidget);
      expect(find.text('精选一'), findsOneWidget);
      expect(find.text('数据来源：AIHOT'), findsOneWidget);
      expect(windows, <String>['24h']);

      await tester.tap(find.byKey(const ValueKey('news-ai-window-week')));
      await tester.pumpAndSettle();
      expect(windows, <String>['24h', '7d']);

      daily.dispose();
      ai.dispose();
    });

    testWidgets('左右滑动切换版面，切换条同步高亮', (tester) async {
      final daily = _serviceWith(
        (_) async => http.Response.bytes(utf8.encode(_okBody), 200),
      );
      final ai = _aiServiceWith((req) async {
        if (req.url.path.endsWith('hot-topics')) {
          return http.Response.bytes(utf8.encode(_hotBody), 200);
        }
        return http.Response.bytes(utf8.encode(_aiItemsBody), 200);
      });

      await tester.pumpWidget(MaterialApp(
        home: DailyNewsPage(service: daily, aiHotService: ai),
      ));
      await tester.pumpAndSettle();

      final pager = find.byKey(const ValueKey('news-pages'));
      expect(pager, findsOneWidget);
      expect(find.text('新闻一'), findsOneWidget);

      // 左滑 → AI速递：版面与切换条选中态一起变（选中段字重 600，未选 400）。
      await tester.drag(pager, const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('热点一'), findsOneWidget);
      expect(find.text('新闻一'), findsNothing);
      expect(_tabActive(tester, 'news-tab-ai'), isTrue);
      expect(_tabActive(tester, 'news-tab-daily'), isFalse);

      // 右滑 → 回每日新闻。
      await tester.drag(pager, const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(find.text('新闻一'), findsOneWidget);
      expect(_tabActive(tester, 'news-tab-daily'), isTrue);
      expect(_tabActive(tester, 'news-tab-ai'), isFalse);

      daily.dispose();
      ai.dispose();
    });

    testWidgets('热点角标条数与实际展示行数一致', (tester) async {
      final longHotBody = utf8.encode(
        '{"schemaVersion":1,"count":8,"items":[${List.generate(
          8,
          (i) => '{"rank":${i + 1},"id":"h$i","title":"热点${i + 1}",'
              '"source":{"name":"来源"},"links":{}}',
        ).join(',')}]}',
      );
      final daily = _serviceWith(
        (_) async => http.Response.bytes(utf8.encode(_okBody), 200),
      );
      final ai = _aiServiceWith((req) async {
        if (req.url.path.endsWith('hot-topics')) {
          return http.Response.bytes(longHotBody, 200);
        }
        return http.Response.bytes(utf8.encode(_aiItemsBody), 200);
      });

      await tester.pumpWidget(MaterialApp(
        home: DailyNewsPage(service: daily, aiHotService: ai),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('news-tab-ai')));
      await tester.pumpAndSettle();

      // API 返回 8 条但只展示 5 条，角标应写 5 而不是 8。
      expect(find.text('5 条'), findsOneWidget);
      expect(find.text('8 条'), findsNothing);
      for (var i = 1; i <= 5; i++) {
        expect(find.text('热点$i'), findsOneWidget);
      }
      expect(find.text('热点6'), findsNothing);

      daily.dispose();
      ai.dispose();
    });
  });
  group('NewsCache 离线缓存', () {
    installCleanEnv();

    test('缓存往返保留两个版面与两个窗口', () async {
      final cache = NewsCache(now: () => DateTime(2026, 11, 19, 12));
      await cache.saveDaily(
        const DailyNews(date: '2026-11-19', news: <String>['甲']),
      );
      await cache.saveAiHot(const <AiHotTopic>[
        AiHotTopic(rank: 1, title: '热一'),
      ]);
      await cache.saveAiItems(
        '24h',
        const <AiHotItem>[AiHotItem(title: '精选甲', score: 5)],
      );
      await cache.saveAiItems(
        '7d',
        const <AiHotItem>[AiHotItem(title: '精选乙', score: 9)],
      );

      final daily = await cache.readDaily();
      expect(daily!.news, <String>['甲']);
      final ai = await cache.readAi();
      expect(ai!.hot!.single.title, '热一');
      expect(ai.itemsFor('24h')!.single.title, '精选甲');
      expect(ai.itemsFor('7d')!.single.score, 9);
    });

    test('超过24小时视为过期', () async {
      var now = DateTime(2026, 11, 19, 12);
      final cache = NewsCache(now: () => now);
      await cache.saveDaily(
        const DailyNews(date: '2026-11-19', news: <String>['甲']),
      );
      expect(await cache.readDaily(), isNotNull);
      now = now.add(const Duration(hours: 25));
      expect(await cache.readDaily(), isNull);
      expect(await cache.readAi(), isNull);
    });
  });
}
