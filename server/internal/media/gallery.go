package media

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// ImageFile 描述磁盘上已有的一张条目图片。
type ImageFile struct {
	Type     string
	Index    int
	Filename string
	Size     int64
}

// ListItemImages 枚举 data/images/{itemID}/{type}/{index}.jpg。
func (s *ImageStore) ListItemImages(itemID string) ([]ImageFile, error) {
	return listImageFiles(filepath.Join(s.root, sanitizeID(itemID)))
}

func listImageFiles(base string) ([]ImageFile, error) {
	entries, err := os.ReadDir(base)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	result := make([]ImageFile, 0, 8)
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		imageType := normalizeTypeName(entry.Name())
		files, err := os.ReadDir(filepath.Join(base, entry.Name()))
		if err != nil {
			continue
		}
		for _, file := range files {
			if file.IsDir() || !strings.EqualFold(filepath.Ext(file.Name()), ".jpg") {
				continue
			}
			index, err := strconv.Atoi(strings.TrimSuffix(file.Name(), filepath.Ext(file.Name())))
			if err != nil {
				continue
			}
			info, err := file.Info()
			if err != nil {
				continue
			}
			result = append(result, ImageFile{
				Type:     imageType,
				Index:    index,
				Filename: file.Name(),
				Size:     info.Size(),
			})
		}
	}

	sort.Slice(result, func(i, j int) bool {
		if result[i].Type == result[j].Type {
			return result[i].Index < result[j].Index
		}
		return result[i].Type < result[j].Type
	})
	return result, nil
}

func normalizeTypeName(dirName string) string {
	switch dirName {
	case "primary":
		return "Primary"
	case "backdrop":
		return "Backdrop"
	case "chapter":
		return "Chapter"
	case "screenshot":
		return "Screenshot"
	case "logo":
		return "Logo"
	case "thumb":
		return "Thumb"
	case "banner":
		return "Banner"
	}
	if dirName == "" {
		return dirName
	}
	return strings.ToUpper(dirName[:1]) + dirName[1:]
}
