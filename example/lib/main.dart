import 'package:example/data/dog/dog_db.dart';
import 'package:example/data/human/human_db.dart';
import 'package:example/home_page.dart';
import 'package:example/isolate_pool.dart';
import 'package:flutter/material.dart';
import 'package:tunai_db/tunai_db.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  IsolatePool.instance.init(poolSize: 2);

  await initDB();
  runApp(const MyApp());
}

Future<void> initDB({bool? singleInstance = true}) async {
  try {
    print('Init Db, singleInstance: $singleInstance');

    final initializer = TunaiDBInitializer();

    initializer.setTables([HumanDb().table, DogDb().table]);

    await initializer.initDatabase(
      'tunai_db_test',
      singleInstance: singleInstance,
    );
  } catch (e) {
    print('Failed to init db . $e');
  }
}

Future<void> closeDB() async {
  return TunaiDBInitializer().close();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const HomePage(),
    );
  }
}
