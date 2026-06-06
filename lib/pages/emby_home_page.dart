import 'package:flutter/material.dart';
import '../models/emby_models.dart';
import '../services/emby_service.dart';
import 'emby_login_page.dart';
import 'emby_video_feed_page.dart';

class EmbyHomePage extends StatefulWidget {
  const EmbyHomePage({super.key});

  @override
  State<EmbyHomePage> createState() => _EmbyHomePageState();
}

class _EmbyHomePageState extends State<EmbyHomePage> {
  List<EmbyLibrary> _libraries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final libs = await EmbyService().getLibraries();
      setState(() { _libraries = libs; });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      setState(() { _loading = false; });
    }
  }

  Future<void> _logout() async {
    await EmbyService().logout();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const EmbyLoginPage()),
      );
    }
  }

  IconData _libIcon(String type) {
    switch (type) {
      case 'movies': return Icons.movie;
      case 'tvshows': return Icons.tv;
      case 'music': return Icons.music_note;
      default: return Icons.folder;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('媒体库', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(icon: const Icon(Icons.logout, color: Colors.white), onPressed: _logout),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.green))
          : _libraries.isEmpty
              ? const Center(child: Text('没有媒体库', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: _libraries.length,
                  itemBuilder: (_, i) {
                    final lib = _libraries[i];
                    return ListTile(
                      leading: Icon(_libIcon(lib.collectionType), color: Colors.green),
                      title: Text(lib.name, style: const TextStyle(color: Colors.white)),
                      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => EmbyVideoFeedPage(library: lib)),
                      ),
                    );
                  },
                ),
    );
  }
}
