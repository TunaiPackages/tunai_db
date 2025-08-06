import 'dart:math';

import 'package:example/data/dog/dog.dart';
import 'package:example/data/dog/dog_db.dart';
import 'package:example/isolate_pool.dart';
import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tunai_db/tunai_db.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final dogDB = DogDb();
  List<Dog> dogs = [];
  bool isLoading = true;
  bool isAddingDog = false;

  @override
  void initState() {
    super.initState();
    _loadDogs();
  }

  Future<void> _loadDogs() async {
    setState(() {
      isLoading = true;
    });

    try {
      final fetchedDogs = await dogDB.fetch();
      setState(() {
        dogs = fetchedDogs;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error loading dogs: $e')));
      }
    }
  }

  Future<void> _addDog() async {
    setState(() {
      isAddingDog = true;
    });

    try {
      final newDog = Dog(
        dogID: _getUniqueID(),
        name: 'Buddy',
        age: 1 + (dogs.length % 10),
        breed: _getRandomBreed(),
        humanID: 0,
      );

      await dogDB.insert(newDog);
      await _loadDogs(); // Reload the list

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${newDog.name}!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding dog: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        isAddingDog = false;
      });
    }
  }

  Future<void> _deleteDog(Dog dog) async {
    // Show confirmation dialog
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Delete ${dog.name}?'),
          content: Text(
            'Are you sure you want to delete ${dog.name}? This action cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) return;

    try {
      await dogDB.delete([DBFilter(fieldName: 'dogID', matched: dog.dogID)]);
      await _loadDogs();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${dog.name} has been deleted'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting ${dog.name}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '🐕 Dog Collection',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24),
        ),
        backgroundColor: Colors.orange.shade100,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: isLoading ? null : _loadDogs,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
          IconButton(
            onPressed: () async {
              _addDogInIsolate();
              _addDog();
            },
            icon: const Icon(Icons.work),
            tooltip: 'Add Dog in Background',
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.orange.shade50, Colors.white],
          ),
        ),
        child: isLoading
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Loading dogs...',
                      style: TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                  ],
                ),
              )
            : dogs.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.pets, size: 80, color: Colors.grey.shade400),
                    const SizedBox(height: 16),
                    Text(
                      'No dogs yet!',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap the + button to add your first dog',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              )
            : RefreshIndicator(
                onRefresh: _loadDogs,
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: dogs.length,
                  itemBuilder: (context, index) {
                    final dog = dogs[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      elevation: 4,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.white, Colors.orange.shade50],
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(16),
                          leading: CircleAvatar(
                            radius: 30,
                            backgroundColor: Colors.orange.shade200,
                            child: Text(
                              dog.name[0].toUpperCase(),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          title: Text(
                            '${dog.name} ${dog.dogID}',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text(
                                'Breed: ${dog.breed}',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                              Text(
                                'Age: ${dog.age} year${dog.age == 1 ? '' : 's'}',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.pets,
                                color: Colors.orange.shade300,
                                size: 24,
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: () => _deleteDog(dog),
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                  size: 20,
                                ),
                                tooltip: 'Delete ${dog.name}',
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: isAddingDog ? null : _addDog,
        backgroundColor: Colors.orange,
        child: isAddingDog
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

Future<void> _addDogInIsolate() async {
  await IsolatePool.instance.execute(
    args: {'rootToken': RootIsolateToken.instance},
    task: (args) async {
      final RootIsolateToken rootToken = args['rootToken'];
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
      await initDB(singleInstance: false);

      final dogDB = DogDb();
      final dogs = await dogDB.fetch();
      print('Fetched dogs in isolate: ${dogs.length}');

      for (var i = 0; i < 5; i++) {
        final newDog = Dog(
          dogID: _getUniqueID(),
          name: 'Buddy From Background',
          age: 1 + (dogs.length % 10),
          breed: _getRandomBreed(),
          humanID: 0,
        );
        await dogDB.insert(newDog);
        print('Added new dog in isolate: ${newDog.name}');
      }

      await closeDB();
    },
  );
}

String _getRandomBreed() {
  final breeds = [
    'Golden Retriever',
    'Labrador',
    'German Shepherd',
    'Bulldog',
    'Poodle',
    'Beagle',
    'Rottweiler',
    'Dachshund',
    'Yorkshire Terrier',
    'Boxer',
    'Pug',
    'Shih Tzu',
    'Chihuahua',
    'Pomeranian',
    'Siberian Husky',
    'Corgi',
    'Shetland Sheepdog',
    'Akita',
    'Bernese Mountain Dog',
    'Great Dane',
    'Doberman',
    'Australian Shepherd',
    'Border Collie',
    'Newfoundland',
    'Saint Bernard',
    'Shiba Inu',
    'Chow Chow',
    'Samoyed',
  ];

  return breeds[Random().nextInt(breeds.length)];
}

int _getUniqueID() {
  return DateTime.now().millisecondsSinceEpoch + Random().nextInt(1000);
}
