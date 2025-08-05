#!/usr/bin/env python3

# ======================================================================== #
# Python version with Telegram integration, time control, and Polling mode #
# ======================================================================== #

import os
import subprocess
import time
import jdatetime
import json
import signal
import sys
import threading
import telebot
import re
from datetime import datetime

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# --- Settings ---
CONTAINER_NAME = "ibsng"
BACKUP_DIR = "/tmp/ibsng_backup_files"
DB_USER = "ibs"
DB_NAME = "IBSng"
RETENTION_DAYS = 3
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
MIN_INTERVAL_HOURS = 2  # Minimum interval between backups (in hours)
POLL_INTERVAL_HOURS = 1  # Check interval (in hours)
BACKUP_SCRIPT = os.path.join(BASE_DIR, "backup_ibsng.sh")  # Path to backup bash script
RESTORE_SCRIPT = os.path.join(BASE_DIR, "restore_ibsng.sh")  # Path to restore bash script
TEMP_DIR = "/tmp/ibsng_restore"  # Temporary directory for restore files
# -----------------

# Global variables for graceful shutdown
shutdown_flag = False
backup_lock = threading.Lock()
config_lock = threading.Lock()
user_states = {}  # User states in Telegram

# Initial configuration loading
config = {}
bot_token = None
chat_id = None

def load_config():
    """Load settings from config file"""
    global config, bot_token, chat_id
    try:
        with config_lock:
            if os.path.exists(CONFIG_FILE):
                with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
                    config = json.load(f)
                    bot_token = config.get('bot_token')
                    chat_id = config.get('chat_id')
            return config
    except Exception as e:
        print(f"❌ Error reading config file: {str(e)}")
        return {}

def save_config(config_data):
    """Save settings to config file"""
    try:
        with config_lock:
            with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
                json.dump(config_data, f, indent=4, ensure_ascii=False)
        return True
    except Exception as e:
        print(f"❌ Error saving config file: {str(e)}")
        return False

def signal_handler(sig, frame):
    """Handle exit signals (Ctrl+C)"""
    global shutdown_flag
    print("\n⚠️ Shutdown signal received. Gracefully exiting...")
    shutdown_flag = True

def send_to_telegram(file_path, bot_token, chat_id):
    """Send file to Telegram with Persian date caption using curl"""
    try:
        # Get current time in Persian (Shamsi) calendar
        persian_date = jdatetime.datetime.now().strftime("%Y/%m/%d")
        persian_time = jdatetime.datetime.now().strftime("%H:%M:%S")
        caption = f"فایل بکاپ IBSng\n\n" f"تاریخ: {persian_date}\n" f"زمان: {persian_time}"

        command = [
            'curl',
            '-X', 'POST',
            f"https://api.telegram.org/bot{bot_token}/sendDocument",
            '-F', f'chat_id={chat_id}',
            '-F', f'document=@{file_path}',
            '-F', f'caption={caption}'
        ]
        
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        response = json.loads(result.stdout)
        
        if response.get('ok'):
            print("✅ Backup file successfully sent to Telegram with Persian date caption.")
            return True
        else:
            print(f"❌ Error sending to Telegram: {response.get('description', 'Unknown error')}")
            return False
            
    except subprocess.CalledProcessError as e:
        print(f"❌ Error executing curl: {e.stderr}")
        return False
    except Exception as e:
        print(f"❌ Error sending to Telegram: {str(e)}")
        return False

def check_backup_interval(config_data):
    """Check time interval since last backup"""
    last_backup = config_data.get('last_backup')
    if last_backup:
        current_time = time.time()
        time_diff = current_time - last_backup
        min_interval = MIN_INTERVAL_HOURS * 3600  # Convert hours to seconds
        
        if time_diff < min_interval:
            remaining_time = min_interval - time_diff
            hours = int(remaining_time // 3600)
            minutes = int((remaining_time % 3600) // 60)
            print(f"⏱️ Last backup was less than {MIN_INTERVAL_HOURS} hours ago.")
            print(f"   Time remaining until next backup: {hours} hours and {minutes} minutes")
            return False
    return True

def run_backup_process(force=False):
    """Execute complete backup process using bash script"""
    with backup_lock:
        # Load settings
        config_data = load_config()
        bot_token_local = config_data.get('bot_token')
        chat_id_local = config_data.get('chat_id')
        
        # Check time interval since last backup (if not forcing)
        if not force and not check_backup_interval(config_data):
            return False
        
        # Set environment variables for bash script
        env = os.environ.copy()
        env.update({
            'CONTAINER_NAME': CONTAINER_NAME,
            'BACKUP_DIR': BACKUP_DIR,
            'DB_USER': DB_USER,
            'DB_NAME': DB_NAME
        })
        
        print("Starting IBSng database backup process...")
        
        # Execute bash backup script
        try:
            result = subprocess.run(
                [BACKUP_SCRIPT],
                env=env,
                capture_output=True,
                text=True,
                check=True
            )
            
            # Extract backup file path from bash script output
            backup_file_path = None
            for line in result.stdout.split('\n'):
                if line.startswith('BACKUP_FILE_PATH='):
                    backup_file_path = line.split('=', 1)[1]
                    break
            
            if backup_file_path and os.path.exists(backup_file_path) and os.path.getsize(backup_file_path) > 0:
                print("✅ Backup created successfully:")
                print(f"   File path: {backup_file_path}")
                file_size = os.path.getsize(backup_file_path)
                print(f"   File size: {file_size} bytes")
                
                try:
                    # Send file to Telegram if settings exist
                    if bot_token_local and chat_id_local:
                        print("Sending file to Telegram...")
                        if send_to_telegram(backup_file_path, bot_token_local, chat_id_local):
                            # Update last backup time if send was successful
                            config_data['last_backup'] = time.time()
                            save_config(config_data)
                        else:
                            print("⚠️ Telegram send failed. Last backup time not updated.")
                    else:
                        print("⚠️ Telegram settings not found. Create config.json to send files.")
                        # Update last backup time even without Telegram
                        config_data['last_backup'] = time.time()
                        save_config(config_data)
                finally:
                    # --- CHANGE: Always delete the local backup file after attempting to send ---
                    try:
                        print(f"🗑️ Deleting local backup file: {backup_file_path}")
                        os.remove(backup_file_path)
                        print("✅ Local backup file deleted successfully.")
                    except OSError as e:
                        print(f"❌ Error deleting local backup file {backup_file_path}: {e}")

                # Delete old backups (This logic remains for other old files in the directory)
                print(f"Deleting backups older than {RETENTION_DAYS} days...")
                cutoff_time = time.time() - (RETENTION_DAYS * 86400)  # 86400 seconds = 1 day
                
                for filename in os.listdir(BACKUP_DIR):
                    if filename.endswith('.dump.gz'):
                        file_path = os.path.join(BACKUP_DIR, filename)
                        if os.path.getmtime(file_path) < cutoff_time:
                            os.remove(file_path)
                            print(f"   Deleted old file: {filename}")
                
                print("✅ Old backup cleanup completed successfully.")
                return True
            else:
                print("❌ Error: Backup file not created or size is zero.")
                return False
                
        except subprocess.CalledProcessError as e:
            print(f"❌ Error executing backup script:")
            print(f"   Error output: {e.stderr}")
            return False
        except Exception as e:
            print(f"❌ Error in backup process: {str(e)}")
            return False

def run_restore_process(file_path, chat_id):
    """Execute database restore process using bash script"""
    global bot
    try:
        # Execute bash restore script with auto 'y' response to confirmation
        process = subprocess.Popen(
            f'echo "y" | {RESTORE_SCRIPT} "{file_path}"',
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        # Read output in chunks to send to Telegram
        output_buffer = ""
        while True:
            output = process.stdout.read(1000)
            if not output and process.poll() is not None:
                break
            if output:
                output_buffer += output
                # Send output in 4000 character chunks (Telegram limit)
                if len(output_buffer) >= 4000:
                    bot.send_message(chat_id, f"```\n{output_buffer[:4000]}\n```", parse_mode="Markdown")
                    output_buffer = output_buffer[4000:]
        
        # Send remaining output
        if output_buffer:
            bot.send_message(chat_id, f"```\n{output_buffer}\n```", parse_mode="Markdown")
        
        # Check for errors
        stderr_output = process.stderr.read()
        if stderr_output:
            bot.send_message(chat_id, f"❌ Errors:\n```\n{stderr_output}\n```", parse_mode="Markdown")
        
        # Check final result
        if process.returncode == 0:
            bot.send_message(chat_id, "✅ بازیابی پایگاه داده با موفقیت انجام شد!")
        else:
            bot.send_message(chat_id, f"❌ بازیابی پایگاه داده ناموفق بود! کد خطا: {process.returncode}")
        
        # Delete temporary file
        try:
            os.remove(file_path)
            print(f"Temporary file deleted: {file_path}")
        except Exception as e:
            print(f"Error deleting temporary file: {str(e)}")
            
    except Exception as e:
        bot.send_message(chat_id, f"❌ خطا در اجرای اسکریپت بازیابی: {str(e)}")
        # Try to delete temporary file on error
        try:
            os.remove(file_path)
        except:
            pass

def backup_polling_thread():
    """Thread for periodic backup checks"""
    global shutdown_flag
    while not shutdown_flag:
        print(f"\n🔄 New check at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        
        # Execute backup process
        backup_success = run_backup_process(force=False)
        
        if backup_success:
            print("✅ Backup completed successfully")
        else:
            print("⚠️ Backup not performed in this check")
        
        # Calculate wait time until next check
        wait_seconds = POLL_INTERVAL_HOURS * 3600
        wait_hours = POLL_INTERVAL_HOURS
        
        print(f"⏳ Waiting until next check: {wait_hours} hours")
        
        # Wait with periodic check for shutdown signal
        for _ in range(wait_seconds):
            if shutdown_flag:
                break
            time.sleep(1)

# Main function for Polling mode
def main():
    """Main function for Polling mode and Telegram bot"""
    global bot, bot_token, chat_id
    
    print("🔄 Starting automatic backup polling mode")
    print(f"   - Check interval: every {POLL_INTERVAL_HOURS} hours")
    print(f"   - Minimum backup interval: every {MIN_INTERVAL_HOURS} hours")
    print(f"   - Backup script: {BACKUP_SCRIPT}")
    print(f"   - Restore script: {RESTORE_SCRIPT}")
    print("   - Use Ctrl+C to stop the script")
    print("=" * 50)
    
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Load initial settings
    load_config()
    
    # Create temporary directory for restore files
    os.makedirs(TEMP_DIR, exist_ok=True)
    
    # Create Telegram bot
    if bot_token:
        bot = telebot.TeleBot(bot_token)
        
        # Define bot commands
        def set_bot_commands():
            commands = [
                telebot.types.BotCommand("status", "وضعیت"),
                telebot.types.BotCommand("restore", "بازیابی"),
                telebot.types.BotCommand("backup", "پشتیبان‌گیری")
            ]
            bot.set_my_commands(commands)
        
        # Set bot commands
        set_bot_commands()
        
        @bot.message_handler(commands=['backup'])
        def handle_backup_command(message):
            """Handle /backup command in Telegram"""
            global chat_id
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                bot.reply_to(message, "❌ شما مجوز اجرای این دستور را ندارید!")
                return
            
            # Send start message
            bot.reply_to(message, "🔄 در حال شروع عملیات بکاپ‌گیری...")

            # Execute backup in separate thread
            def run_backup_and_notify():
                success = run_backup_process(force=True)
                if success:
                    pass
                else:
                    bot.send_message(message.chat.id, "❌ بکاپ با خطا مواجه شد!")
            
            threading.Thread(target=run_backup_and_notify).start()
        
        @bot.message_handler(commands=['status'])
        def handle_status_command(message):
            """Handle /status command in Telegram"""
            global chat_id
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                bot.reply_to(message, "❌ شما مجوز اجرای این دستور را ندارید!")
                return
            
            # Get last backup status
            config_data = load_config()
            last_backup = config_data.get('last_backup')
            
            if last_backup:
                last_time = datetime.fromtimestamp(last_backup).strftime('%Y-%m-%d %H:%M:%S')
                time_diff = time.time() - last_backup
                hours = int(time_diff // 3600)
                minutes = int((time_diff % 3600) // 60)
                
                status_msg = f"📊 وضعیت بکاپ:\n"
                status_msg += f"   آخرین بکاپ: {last_time}\n"
                status_msg += f"   زمان گذشته: {hours} ساعت و {minutes} دقیقه پیش"
            else:
                status_msg = "📊 هنوز بکاپی انجام نشده است."
            
            bot.reply_to(message, status_msg)
        
        @bot.message_handler(commands=['restore'])
        def handle_restore_command(message):
            """Handle /restore command in Telegram"""
            global chat_id, user_states
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                bot.reply_to(message, "❌ شما مجوز اجرای این دستور را ندارید!")
                return
            
            # Set user state to waiting for file
            user_states[message.chat.id] = 'waiting_restore'
            
            # Send guide message
            bot.reply_to(message, 
                        "⚠️ هشدار بسیار مهم: عملیات بازیابی دیتابیس موجود را حذف کرده و با بکاپ جدید جایگزین خواهد کرد.\n\n"
                        "لطفاً فایل بکاپ معتبر را ارسال کنید. فرمت‌های پشتیبانی شده:\n"
                        "1. فایل‌های با پسوند .bak\n"
                        "2. فایل‌های با پسوند .dump.gz\n\n"
                        "برای لغو عملیات، دستور /cancel را ارسال کنید.")
        
        @bot.message_handler(commands=['cancel'])
        def handle_cancel_command(message):
            """Handle /cancel command in Telegram"""
            global user_states
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                bot.reply_to(message, "❌ شما مجوز اجرای این دستور را ندارید!")
                return
            
            # Check user state
            if user_states.get(message.chat.id) == 'waiting_restore':
                user_states[message.chat.id] = None
                bot.reply_to(message, "✅ عملیات بازیابی لغو شد.")
            else:
                bot.reply_to(message, "❌ هیچ عملیات فعال برای لغو وجود ندارد.")
        
        @bot.message_handler(content_types=['document'])
        def handle_document(message):
            """Handle file reception from user"""
            global user_states
            
            # Check user permission
            if str(message.chat.id) != str(chat_id):
                return
            
            # Check user state
            if user_states.get(message.chat.id) != 'waiting_restore':
                return
            
            # Get file info
            file_info = bot.get_file(message.document.file_id)
            file_name = message.document.file_name
            
            # Check file extension (only check type and extension)
            if not (file_name.endswith('.bak') or file_name.endswith('.dump.gz')):
                bot.reply_to(message, "❌ پسوند فایل معتبر نیست. لطفاً فایلی با پسوند .bak یا .dump.gz ارسال کنید.")
                return
            
            # Download file
            downloaded_file = bot.download_file(file_info.file_path)
            
            # Save file in temporary directory
            file_path = os.path.join(TEMP_DIR, file_name)
            with open(file_path, 'wb') as f:
                f.write(downloaded_file)
            
            # Reset user state
            user_states[message.chat.id] = None
            
            # Send start message
            bot.reply_to(message,
            "🔄 در حال شروع عملیات بازیابی دیتابیس...\n\n"
            f"فایل بکاپ: {file_name}\n\n"
            "⚠️ هشدار: این عملیات ممکن است چند دقیقه طول بکشد.\n"
            "لطفاً صبور باشید و از ارسال دستورات جدید خودداری کنید."
            )
            
            # Execute restore in separate thread
            threading.Thread(target=run_restore_process, args=(file_path, message.chat.id)).start()
        
        # Start Telegram bot in separate thread
        def bot_polling():
            while not shutdown_flag:
                try:
                    bot.polling(non_stop=True, interval=1, timeout=10)
                except Exception as e:
                    print(f"❌ Error in Telegram bot: {str(e)}")
                    time.sleep(5)
        
        threading.Thread(target=bot_polling, daemon=True).start()
        print("🤖 Telegram bot activated")
    else:
        print("⚠️ Telegram bot token not found. Bot will not be activated.")
    
    # Start periodic backup check thread
    threading.Thread(target=backup_polling_thread, daemon=True).start()
    
    # Wait for shutdown signal
    while not shutdown_flag:
        time.sleep(1)
    
    print("🛑 Script stopped successfully")
    sys.exit(0)

if __name__ == "__main__":
    main()
