#!/bin/bash
# سكريبت أتمتة رفع التعديلات إلى GitHub لبدء بناء الـ APK تلقائياً

if [ -n "$GITHUB_TOKEN" ]; then
  REPO_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/iggdigd218-dev/almohaseb-v2.git"
else
  REPO_URL="${GITHUB_REPO_URL:-https://github.com/iggdigd218-dev/almohaseb-v2.git}"
fi

echo "🔄 جاري إضافة التعديلات..."
git add .

echo "📝 جاري حفظ التعديلات (Commit)..."
COMMIT_MSG=${1:-"Auto-update from AI Studio: Fix & Enhance"}
git commit -m "$COMMIT_MSG"

echo "🚀 جاري الرفع إلى GitHub (فرع main)..."
git branch -M main
git push -u "$REPO_URL" main --force

if [ $? -eq 0 ]; then
  echo "✅ تم الرفع بنجاح! سيبدأ GitHub Actions الآن ببناء ملف الـ APK تلقائياً."
else
  echo "❌ حدث خطأ أثناء الرفع. تأكد من صلاحية التوكن أو اتصال الإنترنت."
fi
