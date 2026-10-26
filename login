{% extends "base.html" %}{% block content %}<h1>Login</h1>
<form class="stack" method="post"><input type="hidden" name="_csrf" value="{{ csrf_token() }}">
<input type="email" name="email" placeholder="Email" required><input type="password" name="password" placeholder="Password" required>
<button class="btn">Login</button></form>{% endblock %}
