#!/usr/bin/env python
# coding: utf-8

## Here should install first:
#sudo dnf install python3-pyaudio 
#sudo dnf install portaudio-devel redhat-rpm-config

# if video/audio play fails
#sudo dnf swap wireplumber pipewire-media-session
#systemctl --user restart pipewire-media-session

## pre-requisite libraries
#pip install SpeechRecognition
#pip install pyttsx3
#pip install langchain-core
#pip install langchain_ollama
#pip install PyAudio
#pip install flask
#pip install pydub

# import libraries
import speech_recognition as sr
import pyttsx3
import os
from flask import Flask, render_template, request, jsonify
from dotenv import load_dotenv
from langchain_core.prompts import ChatPromptTemplate
from langchain_ollama.llms import OllamaLLM
from pydub import AudioSegment 

load_dotenv()

# AI model setup
template = """
You are an assistant for new questions that I have and when I need a second opinion.
Your style is polite, witty, and succinct.
You address the user respectfully as \"Sir,\" or by name if provided.
You add subtle humor where appropriate, and you always stay in character as a resourceful AI.
Keep the responses short and to the point, and avoid overly verbose or complex replies.
Context / Conversation so far:
{history}
User just said: {question}
Now, Agent, please reply:
"""

prompt = ChatPromptTemplate.from_template(template)
model = OllamaLLM(model="llama3.1")
chain = prompt | model

messages = []
messages.append({"role": "system", "content": "You are a personal agent assistant."})

app = Flask(__name__)

def SpeakText(text):
    engine = pyttsx3.init()  # Reinitialize every time
    engine.setProperty("rate", 180)  # Adjust speed
    engine.setProperty("volume", 1.0)  # Max volume
    engine.say(text)
    engine.runAndWait()
    engine.stop()  # Ensure cleanup

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/process_audio", methods=["POST"])
def process_audio():
    if "audio" not in request.files:
        print("🚨 No audio file received!")  # Debug log
        return jsonify({"error": "No audio file provided"}), 400

    audio_file = request.files["audio"]
    print(f"✅ Received file: {audio_file.filename}")

    input_path = "temp_audio.webm"
    wav_path = "temp_audio.wav"

    audio_file.save(input_path)

    # Debug: Check if file exists
    if not os.path.exists(input_path):
        print("🚨 File save failed!")
        return jsonify({"error": "File save failed!"}), 500

    try:
        audio = AudioSegment.from_file(input_path)
        audio.export(wav_path, format="wav")
        print("✅ Conversion successful!")
    except Exception as e:
        print(f"🚨 Conversion failed: {e}")
        return jsonify({"error": f"Conversion failed: {e}"}), 500

    # Speech recognition
    recognizer = sr.Recognizer()
    with sr.AudioFile(wav_path) as source:
        audio_data = recognizer.record(source)
        try:
            user_message = recognizer.recognize_google(audio_data).lower()
            print(f"✅ Recognized speech: {user_message}")
            # send to agent
            agent_response = send_to_agent(user_message)
            messages.append({"role": "user", "content": user_message})
            messages.append({"role": "agent", "content": agent_response})
        except sr.UnknownValueError:
            print("🚨 Speech not understood!")
            user_message = "Could not understand audio."
            agent_response = "Could not understand audio."
        except sr.RequestError as e:
            print(f"🚨 Speech recognition error: {e}")
            user_message = f"Error: {e}"

    return jsonify({"user": user_message, "response": agent_response})

messages = []
messages.append({"role": "system", "content": "You are a personal agent assistant."})
def send_to_agent(message):
    history_text = "".join([
        f"{msg['role'].title()}: {msg['content']}\n" for msg in messages
    ])
    response = chain.invoke({"history": history_text, "question": message})
    return response



if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)